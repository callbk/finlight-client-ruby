# frozen_string_literal: true

module Finlight
  class Client
    VERSION = "0.1.0"

    # Identifier sent as User-Agent (REST) and x-client-version (WebSocket).
    CLIENT_VERSION = "ruby/finlight-client@#{VERSION}".freeze
  end
end
