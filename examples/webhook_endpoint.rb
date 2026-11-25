# frozen_string_literal: true

# A webhook endpoint as a Rack app.
#
# - Read the raw body and verify it before parsing anything.
# - Answer 2xx at once (finlight waits at most 5 s) and do slow work afterwards, here on a worker thread.
# - Deduplicate on event_id: deliveries are at-least-once.
# - Answer a WrongPayloadVersion (an old v2 body, for example a retry queued before you switched the
#   webhook to v3) with 2xx too, and keep its raw JSON if you need it.
# - Answer a failed verification with 400. Never answer 410: it disables the webhook at once.
#
# Serve it with any Rack server, for example (gem install rackup webrick):
#   FINLIGHT_WEBHOOK_SECRET=... ruby examples/webhook_endpoint.rb

require "finlight"

class WebhookEndpoint
  attr_reader :work

  def initialize(secret: ENV.fetch("FINLIGHT_WEBHOOK_SECRET", ""), &process)
    @secret = secret
    @seen = Set.new # use a shared store (database, Redis) in production
    @mutex = Mutex.new
    @work = Thread::Queue.new
    @process = process || ->(kind, item) { puts "#{kind}: #{item.inspect[0, 120]}" }
    @worker = Thread.new { loop { @process.call(*@work.pop) } }
  end

  def call(env)
    return [405, {}, []] unless env["REQUEST_METHOD"] == "POST"

    raw_body = env["rack.input"]&.read.to_s # the raw bytes, before any JSON parsing
    result = Finlight::Webhooks.construct_event(raw_body, env, @secret)
    case result
    when Finlight::WrongPayloadVersion
      @work << [:legacy, result.raw] # keep it; answer 2xx so the webhook stays enabled
    when Finlight::WebhookEvent
      fresh = @mutex.synchronize { @seen.add?(result.event_id) }
      @work << [:event, result] if fresh
    end
    [204, {}, []]
  rescue Finlight::WebhookVerificationError, Finlight::DecodeError
    [400, {}, []]
  end
end

if $PROGRAM_NAME == __FILE__
  require "rackup"
  Rackup::Server.start(app: WebhookEndpoint.new, Port: Integer(ENV.fetch("PORT", "8080")))
end
