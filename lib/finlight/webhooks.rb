# frozen_string_literal: true

require "json"
require "openssl"

module Finlight
  # Verify and read finlight webhooks on your own server.
  #
  # Always pass the raw request body exactly as received (a String of bytes, or its UTF-8 text).
  # A parsed and re-serialized body never matches the signature.
  module Webhooks
    SIGNATURE_HEADER = "X-Webhook-Signature"
    TIMESTAMP_HEADER = "X-Webhook-Timestamp"
    # Default tolerance in seconds, applied in both directions.
    DEFAULT_TOLERANCE = 300.0

    module_function

    # Verifies a webhook request and reads its body.
    #
    # `headers` may be a Hash (any case, Rack env names such as HTTP_X_WEBHOOK_SIGNATURE included),
    # an Array of [name, value] pairs, or any object that yields name/value pairs from `each`.
    #
    # @param raw_body [String] the body exactly as received
    # @param headers [Hash, Array, #each]
    # @param secret [String] the webhook secret (used as its UTF-8 bytes, never hex-decoded)
    # @param tolerance [Numeric] seconds
    # @param now [Time, #call, nil] the current time (or a callable returning it), for tests
    # @return [WebhookEvent, WrongPayloadVersion] answer both with 2xx
    # @raise [WebhookVerificationError] verification failed
    # @raise [DecodeError] the signed body is not a readable JSON object
    def construct_event(raw_body, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      body = raw_bytes(raw_body)
      pairs = header_pairs(headers)
      signature = find_header(pairs, SIGNATURE_HEADER)
      timestamp = find_header(pairs, TIMESTAMP_HEADER)
      construct_event_from_values(body, signature, timestamp, secret, tolerance: tolerance, now: now)
    end

    # Like construct_event, with the two header values passed as Strings.
    #
    # @return [WebhookEvent, WrongPayloadVersion]
    def construct_event_from_values(raw_body, signature, timestamp, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      body = raw_bytes(raw_body)
      verify_signature(body, signature, timestamp, secret, tolerance: tolerance, now: now)
      parsed = begin
        JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError, EncodingError
        raise DecodeError.new("webhook body is not valid JSON", path: "$")
      end
      raise DecodeError.new("webhook body is not a JSON object", path: "$", raw: parsed) unless parsed.is_a?(Hash)

      present = parsed.key?("payloadVersion")
      version = parsed["payloadVersion"]
      unless v3?(version)
        return WrongPayloadVersion.new(
          detected_version: 2, payload_version: version, payload_version_present: present,
          raw: WireModel.deep_freeze(parsed), link: link_of(parsed)
        )
      end

      Decode.webhook_event(parsed)
    end

    # Checks signature and timestamp only. Returns nil when valid.
    #
    # @raise [WebhookVerificationError]
    def verify_signature(raw_body, signature, timestamp, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      body = raw_bytes(raw_body)
      unless secret.is_a?(String) && !secret.empty?
        raise fail_with("invalid_secret", "the webhook secret must be a non-empty String")
      end
      raise fail_with("missing_signature", "no #{SIGNATURE_HEADER} header") if signature.nil? || signature == ""
      raise fail_with("missing_timestamp", "no #{TIMESTAMP_HEADER} header") if timestamp.nil? || timestamp == ""

      [[SIGNATURE_HEADER, signature], [TIMESTAMP_HEADER, timestamp]].each do |name, value|
        unless value.is_a?(String) && value.b.ascii_only?
          raise fail_with("non_ascii_header", "header #{name} contains non-ASCII characters")
        end
      end
      unless signature.start_with?("sha256=")
        raise fail_with("unsupported_signature_scheme", "the signature must start with sha256=")
      end

      sent_time = TimeParse.parse(timestamp)
      raise fail_with("unparseable_timestamp", "#{TIMESTAMP_HEADER} is not an RFC 3339 timestamp") unless sent_time

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.b, "#{timestamp.b}.".b + body)
      given = signature.b[7..]
      unless given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(given, expected)
        raise fail_with("signature_mismatch", "the signature does not match")
      end

      current = resolve_now(now)
      if (current - sent_time).abs > tolerance
        raise fail_with("timestamp_outside_tolerance", "the timestamp is outside the tolerance")
      end

      nil
    end

    # -- internal ------------------------------------------------------------------

    def fail_with(reason, message)
      WebhookVerificationError.new("webhook verification failed: #{message}", reason: reason)
    end

    def raw_bytes(raw_body)
      unless raw_body.is_a?(String)
        raise fail_with("invalid_raw_body",
                        "raw_body must be the request body as received (a String), not parsed JSON")
      end

      raw_body.b
    end

    def header_pairs(headers)
      case headers
      when nil then []
      when Hash then headers.to_a
      when Array then headers
      else
        raise fail_with("missing_signature", "headers must be a Hash or name/value pairs") unless
          headers.respond_to?(:each)

        headers.to_enum(:each).map { |name, value| [name, value] }
      end
    end

    def normalize_name(name)
      lowered = name.to_s.downcase
      lowered = lowered.delete_prefix("http_").tr("_", "-") if lowered.start_with?("http_")
      lowered
    end

    def find_header(pairs, wanted)
      wanted_l = wanted.downcase
      found = pairs.select { |pair| pair.is_a?(Array) && normalize_name(pair[0]) == wanted_l }.map { |p| p[1] }
      return nil if found.empty?
      raise fail_with("duplicate_header", "header #{wanted} was sent more than once") if found.size > 1

      value = found.first
      if value.is_a?(Array)
        raise fail_with("duplicate_header", "header #{wanted} was sent more than once") if value.size != 1

        value = value.first
      end
      value&.to_s
    end

    def resolve_now(now)
      value = now.respond_to?(:call) ? now.call : now
      value ||= Time.now
      raise ArgumentError, "now must be a Time" unless value.is_a?(Time)

      value
    end

    # Same rule as the server (v === 3): a JSON number equal to 3, never a boolean or a String.
    def v3?(value)
      value.is_a?(Numeric) && value == 3
    end

    def link_of(parsed)
      return parsed["link"] if parsed["link"].is_a?(String)

      data = parsed["data"]
      data.is_a?(Hash) && data["link"].is_a?(String) ? data["link"] : nil
    end

    private_class_method :fail_with, :raw_bytes, :header_pairs, :normalize_name, :find_header, :resolve_now,
                         :v3?, :link_of
  end
end
