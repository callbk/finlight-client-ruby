# frozen_string_literal: true

require "openssl"

RSpec.describe Finlight::WebhookService do
  let(:secret) { "test-secret" }
  let(:body) do
    '{"link":"https://example.com/news/1","title":"Test Article",' \
      '"publishDate":"2025-06-01T12:00:00Z","source":"example.com","language":"en",' \
      '"confidence":"0.95","sentiment":"positive"}'
  end

  def sign(message, key)
    OpenSSL::HMAC.hexdigest("SHA256", key, message)
  end

  it "verifies a valid signature without timestamp" do
    article = described_class.construct_event(body, sign(body, secret), secret)
    expect(article.title).to eq("Test Article")
    expect(article.link).to eq("https://example.com/news/1")
    expect(article.confidence).to eq(0.95)
  end

  it "verifies a valid signature with sha256= prefix" do
    article = described_class.construct_event(body, "sha256=#{sign(body, secret)}", secret)
    expect(article.title).to eq("Test Article")
  end

  it "verifies a signature with timestamp" do
    timestamp = Time.now.utc.iso8601
    signature = sign("#{timestamp}.#{body}", secret)
    article = described_class.construct_event(body, signature, secret, timestamp)
    expect(article.title).to eq("Test Article")
  end

  it "rejects an invalid signature" do
    expect { described_class.construct_event(body, "deadbeef", secret) }
      .to raise_error(Finlight::WebhookVerificationError, /signature/i)
  end

  it "rejects a signature made with the wrong secret" do
    signature = sign(body, "other-secret")
    expect { described_class.construct_event(body, signature, secret) }
      .to raise_error(Finlight::WebhookVerificationError)
  end

  it "rejects an expired timestamp" do
    timestamp = (Time.now.utc - 600).iso8601
    signature = sign("#{timestamp}.#{body}", secret)
    expect { described_class.construct_event(body, signature, secret, timestamp) }
      .to raise_error(Finlight::WebhookVerificationError, /tolerance/i)
  end

  it "rejects an invalid JSON payload" do
    bad_body = "not json"
    signature = sign(bad_body, secret)
    expect { described_class.construct_event(bad_body, signature, secret) }
      .to raise_error(Finlight::WebhookVerificationError, /json/i)
  end
end
