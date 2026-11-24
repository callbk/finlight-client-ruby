# frozen_string_literal: true

# Stream articles in real time; stops after 5. Run: FINLIGHT_API_KEY=... ruby examples/stream.rb
# Optional: FINLIGHT_WSS_URL (for example wss://wss.dev.finlight.me).

require "finlight"

module StreamExample
  def self.run(max_events: 5)
    client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"),
                                  **{ wss_url: ENV.fetch("FINLIGHT_WSS_URL", nil) }.compact)
    stream = client.stream(
      query: "ticker:NVDA",
      include: ["companies"],
      include_updates: true,
      # Admission comes before the server checks the subscribe; it does not mean it was accepted.
      on_admitted: ->(info) { puts "admitted, lease #{info.lease_id}" },
      # No automatic backfill: fill the gap yourself if you need it, for example with
      # client.articles.search_all(from: info.last_seen_at, order_by: "availableAt").
      on_reconnect: ->(info) { puts "reconnected (#{info.reason}); last seen #{info.last_seen_at.inspect}" },
      on_error: ->(error) { puts "stream problem (still running): #{error.message}" },
      on_quota_wait: ->(info) { puts "WebSocket quota used up; next try in #{info.next_attempt_in.round} s" }
    )
    count = 0
    stream.each do |event|
      next if event.kind == Finlight::StreamEventKind::OTHER # an event this SDK does not know yet

      puts "#{event.kind} #{event.data.id} #{event.data.title}"
      count += 1
      break if count >= max_events # leaving the loop closes the socket
    end
  rescue Finlight::PreemptedError => e
    puts "another connection took over: #{e.reason} #{e.new_lease_id}"
  rescue Finlight::ApiError => e
    puts "stream ended: #{e.api_kind} #{e.status} #{e.detail}"
  end
end

StreamExample.run if $PROGRAM_NAME == __FILE__
