# frozen_string_literal: true

require "openssl"

RSpec.describe "webhooks, beyond the kit" do
  let(:secret) { "a" * 64 }
  let(:timestamp) { "2026-11-23T21:04:05.123Z" }
  let(:now) { Time.utc(2026, 11, 23, 21, 4, 6) }

  def sign(body, timestamp, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body.b}".b)}"
  end

  def v3_body(extra = {})
    data = Kit.load("fixtures/decode/raw-skeleton.json")["wire"]
    JSON.generate({ "eventId" => "evt_1", "event" => "article.created", "occurredAt" => timestamp,
                    "payloadVersion" => 3, "subscriptionId" => "s", "data" => data }.merge(extra))
  end

  def construct(body, headers = nil, **options)
    headers ||= { "X-Webhook-Signature" => sign(body, timestamp, secret), "X-Webhook-Timestamp" => timestamp }
    Finlight::Webhooks.construct_event(body, headers, secret, now: now, **options)
  end

  def reason_of
    yield
    nil
  rescue Finlight::WebhookVerificationError => e
    e.reason
  end

  it "verifies a non-ASCII body given as bytes or as a string" do
    body = v3_body("data" => Kit.load("fixtures/decode/non-ascii.json")["wire"])
    expect(construct(body.b)).to be_a(Finlight::WebhookEvent)
    expect(construct(body.dup.force_encoding("UTF-8")).data.title).to include("示例")
  end

  it "rejects a parsed body and an empty secret with WebhookVerificationError" do
    expect(reason_of { Finlight::Webhooks.construct_event({ "a" => 1 }, {}, secret) }).to eq("invalid_raw_body")
    expect(reason_of { Finlight::Webhooks.verify_signature("{}", "sha256=x", timestamp, "") }).to eq("invalid_secret")
  end

  it "finds headers in any case, in Rack env form, as pairs and as multi-value Arrays" do
    body = v3_body
    sig = sign(body, timestamp, secret)
    rack = { "HTTP_X_WEBHOOK_SIGNATURE" => sig, "HTTP_X_WEBHOOK_TIMESTAMP" => timestamp, "rack.input" => nil }
    expect(construct(body, rack)).to be_a(Finlight::WebhookEvent)
    expect(construct(body, [["x-webhook-signature", sig], ["X-WEBHOOK-TIMESTAMP", timestamp]]))
      .to be_a(Finlight::WebhookEvent)
    expect(construct(body, { "x-webhook-signature" => [sig], "x-webhook-timestamp" => [timestamp] }))
      .to be_a(Finlight::WebhookEvent)
  end

  it "fails closed on duplicate and non-ASCII headers" do
    body = v3_body
    sig = sign(body, timestamp, secret)
    dup = { "X-Webhook-Signature" => sig, "x-webhook-signature" => sig, "X-Webhook-Timestamp" => timestamp }
    expect(reason_of { construct(body, dup) }).to eq("duplicate_header")
    multi = { "X-Webhook-Signature" => [sig, sig], "X-Webhook-Timestamp" => timestamp }
    expect(reason_of { construct(body, multi) }).to eq("duplicate_header")
    expect(reason_of { construct(body, { "X-Webhook-Signature" => "sha256=ä", "X-Webhook-Timestamp" => timestamp }) })
      .to eq("non_ascii_header")
  end

  it "applies the tolerance in both directions and accepts a callable clock" do
    body = v3_body
    headers = { "X-Webhook-Signature" => sign(body, timestamp, secret), "X-Webhook-Timestamp" => timestamp }
    late = -> { Time.utc(2026, 11, 23, 21, 10) }
    expect(reason_of { Finlight::Webhooks.construct_event(body, headers, secret, now: late) })
      .to eq("timestamp_outside_tolerance")
    expect(Finlight::Webhooks.construct_event(body, headers, secret, now: late, tolerance: 600))
      .to be_a(Finlight::WebhookEvent)
    expect(Finlight::Webhooks::DEFAULT_TOLERANCE).to eq(300.0)
  end

  it "returns WrongPayloadVersion for anything but the JSON number 3 (R-HOOK-2)" do
    v2 = JSON.generate({ "link" => "https://x.example/a", "title" => "t" })
    result = construct(v2)
    expect(result).to be_a(Finlight::WrongPayloadVersion)
    expect([result.detected_version, result.payload_version_present, result.link]).to eq([2, false, "https://x.example/a"])

    string = construct(v3_body("payloadVersion" => "3"))
    expect(string).to be_a(Finlight::WrongPayloadVersion)
    expect(string.payload_version).to eq("3")
    expect(string.payload_version_present).to be(true)
    expect(construct(v3_body("payloadVersion" => true))).to be_a(Finlight::WrongPayloadVersion)
    expect(construct(v3_body("payloadVersion" => 2))).to be_a(Finlight::WrongPayloadVersion)

    float = construct(v3_body.sub('"payloadVersion":3', '"payloadVersion":3.0'))
    expect(float).to be_a(Finlight::WebhookEvent)
  end

  it "checks the signature before anything else, even for v2 bodies" do
    v2 = JSON.generate({ "link" => "https://x.example/a" })
    headers = { "X-Webhook-Signature" => sign(v2, timestamp, secret), "X-Webhook-Timestamp" => timestamp }
    expect(reason_of { construct("#{v2} ", headers) }).to eq("signature_mismatch")
  end

  it "raises DecodeError for a signed body that is not a JSON object" do
    expect { construct("[1,2]") }.to raise_error(Finlight::DecodeError)
    expect { construct("not json") }.to raise_error(Finlight::DecodeError)
  end

  it "verify_signature returns nil when valid" do
    body = v3_body
    expect(Finlight::Webhooks.verify_signature(body, sign(body, timestamp, secret), timestamp, secret, now: now))
      .to be_nil
  end

  it "marks test deliveries" do
    expect(construct(v3_body("eventId" => "evt_test123")).test?).to be(true)
    expect(construct(v3_body).test?).to be(false)
  end
end
