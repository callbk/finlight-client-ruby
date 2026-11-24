# frozen_string_literal: true

require "json"

module Finlight
  # Common base of every error the SDK raises. Rescue it with `rescue Finlight::Error`.
  #
  # Each error has a {#kind} string: "api", "validation", "network", "timeout", "decode",
  # "webhook_verification" or "preempted". The original error of a foreign library stays
  # reachable through Ruby's `cause`.
  module Error
    # @return [String] the kind of the error
    def kind
      self.class::KIND
    end
  end

  # One entry of `errors[]` in a problem response, or of `details[]` in a stream error.
  #
  # @!attribute field [String, nil] the request field the issue is about
  # @!attribute issue [String, nil] a human-readable text, not a stable value
  # @!attribute allowed_values [Array<String>, nil] the allowed values of a closed vocabulary
  # @!attribute constraints [Hash{String=>String}, nil] rule => text, only on stream errors
  FieldIssue = Data.define(:field, :issue, :allowed_values, :constraints) do
    def initialize(field: nil, issue: nil, allowed_values: nil, constraints: nil)
      super
    end
  end

  # The API answered with an error (REST, a refused WebSocket dial, or a `connection.error` frame).
  #
  # There is one subclass per known problem code. An unknown code, or a body without a code,
  # gives a plain ApiError with {#api_kind} "other".
  class ApiError < StandardError
    include Error

    KIND = "api"
    API_KIND = "other"

    # @return [Integer, nil] HTTP status (nil for errors that arrive inside a stream)
    attr_reader :status
    # @return [String, nil] problem code (open: unknown codes are kept), nil without a code
    attr_reader :code
    # @return [String, nil] problem type URL
    attr_reader :type
    # @return [String, nil]
    attr_reader :title
    # @return [String, nil]
    attr_reader :detail
    # @return [String, nil] the server's requestId, else the X-Request-Id the SDK sent
    attr_reader :request_id
    # @return [Array<FieldIssue>]
    attr_reader :errors
    # @return [String, nil] the error body as text, exactly as received
    attr_reader :raw

    def initialize(message = nil, status: nil, code: nil, type: nil, title: nil, detail: nil,
                   request_id: nil, errors: [], raw: nil)
      @status = status
      @code = code
      @type = type
      @title = title
      @detail = detail
      @request_id = request_id
      @errors = errors.freeze
      @raw = raw
      super(message || default_message)
    end

    # @return [String] validation_failed, cursor_invalid, cursor_mismatch, unauthorized, forbidden,
    #   not_found, rate_limited, internal_error or other
    def api_kind
      self.class::API_KIND
    end

    # @return [Object, nil] the error body parsed as JSON (Hash, Array, ...), nil when it is not JSON
    def raw_json
      return nil if @raw.nil? || @raw.empty?

      JSON.parse(@raw)
    rescue JSON::ParserError
      nil
    end

    private

    def default_message
      text = "finlight API error"
      text += " #{@status}" if @status
      text += " #{@code}" if @code
      text += ": #{@detail}" if @detail
      text
    end
  end

  # VALIDATION_FAILED (400).
  class ValidationFailedError < ApiError
    API_KIND = "validation_failed"
  end

  # CURSOR_INVALID (400): the cursor cannot be read.
  class CursorInvalidError < ApiError
    API_KIND = "cursor_invalid"
  end

  # CURSOR_MISMATCH (400): filters or sort changed since the cursor was issued.
  class CursorMismatchError < ApiError
    API_KIND = "cursor_mismatch"
  end

  # UNAUTHORIZED (401): missing or invalid API key.
  class UnauthorizedError < ApiError
    API_KIND = "unauthorized"
  end

  # FORBIDDEN (403): the plan does not include this.
  class ForbiddenError < ApiError
    API_KIND = "forbidden"
  end

  # NOT_FOUND (404).
  class NotFoundError < ApiError
    API_KIND = "not_found"
  end

  # RATE_LIMITED (429): monthly quota or burst limit.
  class RateLimitedError < ApiError
    API_KIND = "rate_limited"

    # @return [String] "monthly", "burst", "unknown" or a newer value as sent
    attr_reader :limit_type
    # @return [Float, nil] the Retry-After header in seconds
    attr_reader :retry_after

    def initialize(message = nil, limit_type: RateLimitType::UNKNOWN, retry_after: nil, **fields)
      @limit_type = limit_type
      @retry_after = retry_after
      super(message, **fields)
    end
  end

  # INTERNAL_ERROR (5xx).
  class InternalServerError < ApiError
    API_KIND = "internal_error"
  end

  # A request was rejected locally, before anything was sent. Also an ArgumentError.
  class ValidationError < ArgumentError
    include Error

    KIND = "validation"

    # @return [String, nil] the rejected parameter
    attr_reader :param

    def initialize(message = nil, param: nil)
      @param = param
      super(message)
    end
  end

  # The network failed (connection refused, reset, TLS error, ...). The original error is `cause`.
  class NetworkError < StandardError
    include Error

    KIND = "network"
  end

  # A request or a dial timed out. Also a NetworkError.
  class TimeoutError < NetworkError
    KIND = "timeout"
  end

  # A single response could not be read.
  class DecodeError < StandardError
    include Error

    KIND = "decode"

    # @return [String, nil] JSON path of the value that did not fit
    attr_reader :path
    # @return [Object, nil] the value that did not fit
    attr_reader :raw

    def initialize(message = nil, path: nil, raw: nil)
      @path = path
      @raw = raw
      super(message)
    end
  end

  # A webhook failed verification. {#reason} is one of invalid_raw_body, invalid_secret,
  # missing_signature, missing_timestamp, duplicate_header, non_ascii_header,
  # unsupported_signature_scheme, unparseable_timestamp, signature_mismatch,
  # timestamp_outside_tolerance.
  class WebhookVerificationError < StandardError
    include Error

    KIND = "webhook_verification"

    # @return [String]
    attr_reader :reason

    def initialize(message = nil, reason:)
      @reason = reason
      super(message || "webhook verification failed: #{reason}")
    end
  end

  # The server ended the stream with `connection.preempted`.
  #
  # Terminal for reason "connection_limit" (another connection took the slot). For reason
  # "quota_exceeded" the stream waits for the quota by default (see Config#quota_reconnect).
  class PreemptedError < StandardError
    include Error

    KIND = "preempted"

    # @return [String, nil] "connection_limit", "quota_exceeded" or a newer value
    attr_reader :reason
    # @return [String, nil]
    attr_reader :new_lease_id
    # @return [Integer, nil] epoch milliseconds
    attr_reader :timestamp

    def initialize(message = nil, reason: nil, new_lease_id: nil, timestamp: nil)
      @reason = reason
      @new_lease_id = new_lease_id
      @timestamp = timestamp
      super(message || "stream preempted: #{reason}")
    end
  end

  # Builds API errors from HTTP answers and stream frames. Internal.
  module ErrorParser
    CODE_CLASSES = {
      "VALIDATION_FAILED" => ValidationFailedError,
      "CURSOR_INVALID" => CursorInvalidError,
      "CURSOR_MISMATCH" => CursorMismatchError,
      "UNAUTHORIZED" => UnauthorizedError,
      "FORBIDDEN" => ForbiddenError,
      "NOT_FOUND" => NotFoundError,
      "RATE_LIMITED" => RateLimitedError,
      "INTERNAL_ERROR" => InternalServerError
    }.freeze

    module_function

    # Error class for a status without a problem code (NestJS form, refused dial).
    def class_for_status(status)
      case status
      when 400 then ValidationFailedError
      when 401 then UnauthorizedError
      when 403 then ForbiddenError
      when 404 then NotFoundError
      when 429 then RateLimitedError
      else status.is_a?(Integer) && status >= 500 ? InternalServerError : ApiError
      end
    end

    # The one place that sorts a 429 into monthly, burst or unknown. The limitType member wins and
    # is kept as sent (open list); without it the detail text decides (exact, case-sensitive).
    def classify_rate_limit(limit_type, detail)
      return limit_type if limit_type.is_a?(String) && !limit_type.empty?

      if detail.is_a?(String)
        return RateLimitType::MONTHLY if detail.include?("Exceeded token limit")
        return RateLimitType::BURST if detail.include?("Exceeded rate limit")
      end
      RateLimitType::UNKNOWN
    end

    def issues_from(value)
      return [] unless value.is_a?(Array)

      value.filter_map do |item|
        next unless item.is_a?(Hash)

        constraints = item["constraints"]
        constraints = constraints.to_h { |k, v| [k.to_s, v.to_s] }.freeze if constraints.is_a?(Hash)
        constraints = nil unless constraints.is_a?(Hash)
        issue = item["issue"]
        issue = constraints.values.join("; ") if !issue.is_a?(String) && constraints && !constraints.empty?
        allowed = item["allowedValues"]
        FieldIssue.new(
          field: string_or_nil(item["field"]),
          issue: string_or_nil(issue),
          allowed_values: allowed.is_a?(Array) ? allowed.grep(String).freeze : nil,
          constraints: constraints
        )
      end
    end

    def string_or_nil(value)
      value.is_a?(String) ? value : nil
    end

    # Error for a non-2xx REST answer. Reading order: application/problem+json, then the NestJS
    # form {statusCode, message}, then a body that is not JSON (status plus text).
    def from_response(status, content_type, body, sent_request_id:, retry_after: nil)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub("?") unless text.valid_encoding?
      parsed = parse_json(text)
      ctype = content_type.to_s.downcase

      if parsed.is_a?(Hash) && (ctype.include?("problem+json") ||
                                (parsed.key?("code") && (parsed.key?("type") || parsed.key?("title"))))
        return from_problem(status, parsed, text, sent_request_id, retry_after)
      end
      if parsed.is_a?(Hash) && parsed.key?("statusCode") && parsed.key?("message")
        return from_nest(status, parsed, text, sent_request_id, retry_after)
      end

      snippet = text.strip
      snippet = "#{snippet[0, 200]}..." if snippet.length > 200
      message = "finlight API error #{status}"
      message += ": #{snippet}" unless snippet.empty?
      fields = { status: status, detail: text.empty? ? nil : text, request_id: sent_request_id, raw: text }
      if status == 429
        return RateLimitedError.new(message, limit_type: RateLimitType::UNKNOWN, retry_after: retry_after,
                                             **fields)
      end

      ApiError.new(message, **fields)
    end

    def parse_json(text)
      return nil if text.strip.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def from_problem(status, parsed, text, sent_request_id, retry_after)
      code = string_or_nil(parsed["code"])
      detail = string_or_nil(parsed["detail"])
      problem_status = parsed["status"]
      status = problem_status if status.nil? && problem_status.is_a?(Integer)
      fields = {
        status: status, code: code, type: string_or_nil(parsed["type"]),
        title: string_or_nil(parsed["title"]), detail: detail,
        request_id: string_or_nil(parsed["requestId"]) || sent_request_id,
        errors: issues_from(parsed["errors"]), raw: text
      }
      message = "finlight API error #{status}"
      message += " #{code}" if code
      message += ": #{detail}" if detail
      if code == "RATE_LIMITED" || (code.nil? && status == 429)
        return RateLimitedError.new(message, limit_type: classify_rate_limit(parsed["limitType"], detail),
                                             retry_after: retry_after, **fields)
      end

      CODE_CLASSES.fetch(code, ApiError).new(message, **fields)
    end

    def from_nest(status, parsed, text, sent_request_id, retry_after)
      msg = parsed["message"]
      if msg.is_a?(Array)
        detail = msg.join("; ")
        issues = msg.map { |m| FieldIssue.new(issue: m.to_s) }
      else
        detail = msg&.to_s
        issues = []
      end
      message = "finlight API error #{status}"
      message += ": #{detail}" if detail
      fields = {
        status: status, detail: detail, title: string_or_nil(parsed["error"]),
        request_id: sent_request_id, errors: issues, raw: text
      }
      if status == 429
        return RateLimitedError.new(message, limit_type: classify_rate_limit(nil, detail),
                                             retry_after: retry_after, **fields)
      end

      # No code in this form: the HTTP status picks the kind.
      class_for_status(status).new(message, **fields)
    end
  end
end
