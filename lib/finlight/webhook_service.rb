# frozen_string_literal: true

require "json"
require "openssl"

module Finlight
  # Securely receives and verifies webhook events from finlight: HMAC-SHA256
  # signature verification with replay attack protection.
  module WebhookService
    SIGNATURE_PREFIX = "sha256="
    REPLAY_TOLERANCE_SECONDS = 5 * 60

    module_function

    # Constructs and verifies a webhook event from raw request data.
    #
    # @example Rack/Rails endpoint
    #   article = Finlight::WebhookService.construct_event(
    #     request.raw_post,
    #     request.headers["X-Webhook-Signature"],
    #     ENV["WEBHOOK_SECRET"],
    #     request.headers["X-Webhook-Timestamp"]
    #   )
    #
    # @param raw_body [String] the raw, unparsed request body
    # @param signature [String] the X-Webhook-Signature header (with or
    #   without the "sha256=" prefix)
    # @param endpoint_secret [String] your webhook secret from the dashboard
    # @param timestamp [String, nil] the X-Webhook-Timestamp header; when
    #   given it is included in the signed message and checked against a
    #   5-minute replay tolerance
    # @return [Article] the verified and parsed article
    # @raise [WebhookVerificationError] if verification fails
    def construct_event(raw_body, signature, endpoint_secret, timestamp = nil)
      timestamp = nil if timestamp.to_s.empty?
      normalized = signature.to_s.delete_prefix(SIGNATURE_PREFIX)

      message = timestamp ? "#{timestamp}.#{raw_body}" : raw_body
      expected = compute_signature(message, endpoint_secret)
      unless secure_compare(normalized, expected)
        raise WebhookVerificationError, "Invalid webhook signature"
      end

      verify_timestamp(timestamp) if timestamp

      parse_payload(raw_body)
    end

    def compute_signature(payload, secret)
      OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
    end

    def verify_timestamp(timestamp)
      begin
        webhook_time = FlexTime.parse(timestamp)
      rescue Error
        raise WebhookVerificationError, "Invalid timestamp format"
      end

      if (Time.now.utc - webhook_time).abs > REPLAY_TOLERANCE_SECONDS
        raise WebhookVerificationError, "Webhook timestamp outside allowed tolerance"
      end
    end

    def parse_payload(raw_body)
      data = begin
        JSON.parse(raw_body)
      rescue JSON::ParserError
        raise WebhookVerificationError, "Invalid JSON payload"
      end

      begin
        Article.from_h(data)
      rescue StandardError => e
        raise WebhookVerificationError, "Invalid article data: #{e.message}"
      end
    end

    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      OpenSSL.fixed_length_secure_compare(a, b)
    end
  end
end
