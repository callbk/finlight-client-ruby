# frozen_string_literal: true

require "base64"

RSpec.describe "Conformance W: webhooks" do
  def header_value(headers, name)
    headers.find { |k, _| k.casecmp?(name) }&.last
  end

  Kit.fixtures("fixtures/webhook").each do |id, name|
    it "#{id} #{Kit.case_titles[id]}", kit_case: id do
      fx = Kit.load("fixtures/webhook/#{name}")
      raw = Base64.strict_decode64(fx["request"]["rawBodyBase64"])
      expect(raw.dup.force_encoding("UTF-8")).to eq(fx["request"]["rawBody"])
      headers = fx["request"]["headers"]
      now = FinlightInternal::TimeParse.parse(fx["verify"]["now"])
      tolerance = fx["verify"]["toleranceSeconds"]
      expect_ = fx["expect"]
      run = ->(body) { Finlight::Webhooks.construct_event(body, headers, fx["secret"], tolerance: tolerance, now: now) }

      case expect_["outcome"]
      when "event"
        # The raw bytes and their UTF-8 string give the same result.
        [raw, raw.dup.force_encoding("UTF-8")].each do |body|
          event = run.call(body)
          want = expect_["event"]
          expect(event).to be_a(Finlight::WebhookEvent)
          expect(event.event_id).to eq(want["eventId"])
          expect(event.event).to eq(want["event"])
          expect(event.occurred_at).to eq(want["occurredAt"])
          expect(event.subscription_id).to eq(want["subscriptionId"])
          expect(event.test?).to be(want["isTest"])
          expect(event.data.link).to eq(want["link"])
          expect(event.changed_fields).to eq(want["changedFields"])
          expect(event.payload_version).to eq(3)
          expect(event.raw_json).to eq(JSON.parse(fx["request"]["rawBody"]))
        end
        event = run.call(raw)
        case id
        when "W-02" then expect(event.changed_fields).to eq(%w[title content])
        when "W-03" then expect(event.data.content_present?).to be(false)
        when "W-04"
          expect(event.data.available_at).to be_nil
          expect(event.occurred_at).to eq(event.data.first_seen_at)
          expect([event.data.content_present?, event.data.sentiment_present?, event.data.companies_present?,
                  event.data.events_present?]).to eq([false, false, false, false])
        end
        # The two-string variant gives the same event.
        same = Finlight::Webhooks.construct_event_from_values(
          raw, header_value(headers, "X-Webhook-Signature"), header_value(headers, "X-Webhook-Timestamp"),
          fx["secret"], tolerance: tolerance, now: now
        )
        expect(same).to eq(event)
      when "wrongPayloadVersion"
        result = run.call(raw)
        expect(result).to be_a(Finlight::WrongPayloadVersion)
        expect(result).not_to be_a(Exception)
        expect(result.detected_version).to eq(expect_["detectedVersion"])
        expect(result.payload_version_present).to eq(expect_["payloadVersionPresent"])
        expect(result.payload_version).to be_nil
        expect(result.link).to eq(expect_["link"])
        expect(result.raw).to eq(JSON.parse(fx["request"]["rawBody"]))
        expect(result.raw_json).to eq(result.raw)
      when "error"
        expect { run.call(raw) }.to raise_error(Finlight::WebhookVerificationError) { |e|
          expect(e.reason).to eq(expect_["reason"])
          expect(e.kind).to eq("webhook_verification")
        }
        expect do
          Finlight::Webhooks.construct_event_from_values(
            raw, header_value(headers, "X-Webhook-Signature"), header_value(headers, "X-Webhook-Timestamp"),
            fx["secret"], tolerance: tolerance, now: now
          )
        end.to raise_error(Finlight::WebhookVerificationError) { |e| expect(e.reason).to eq(expect_["reason"]) }
      else raise "unknown outcome"
      end
    end
  end
end
