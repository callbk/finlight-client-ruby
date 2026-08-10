# frozen_string_literal: true

require "logger"

module Finlight
  # Default logger shared by the clients: warnings and errors to stderr.
  # Pass your own +logger:+ to the client or WebSocket clients to override.
  module Logging
    module_function

    def default
      @default ||= Logger.new($stderr, level: Logger::WARN, progname: "finlight")
    end
  end
end
