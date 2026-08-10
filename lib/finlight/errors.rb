# frozen_string_literal: true

module Finlight
  # Base class for all errors raised by this library.
  class Error < StandardError; end

  # Raised when the API responds with a non-success status code.
  class ApiError < Error
    attr_reader :status_code, :body

    def initialize(status_code, body)
      @status_code = status_code
      @body = body
      super("finlight: API request failed with status #{status_code}: #{body}")
    end
  end

  # Raised when the streaming server permanently rejects the connection
  # (close code 1008). Reconnecting will not help; contact support.
  class BlockedError < Error
    def initialize(msg = "finlight: connection rejected by server (blocked)")
      super
    end
  end

  # Raised when webhook signature or timestamp verification fails.
  class WebhookVerificationError < Error; end
end
