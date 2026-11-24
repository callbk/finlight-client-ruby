# frozen_string_literal: true

module Finlight
  # SDK version. The single source for the gem version, the User-Agent and x-client-version.
  VERSION = "1.0.0"

  # The only payloadVersion this SDK speaks: subscribe frames always carry the JSON integer 3.
  PAYLOAD_VERSION = 3

  # User-Agent sent on every REST request and WebSocket dial.
  USER_AGENT = "finlight-client-ruby/#{VERSION}".freeze
end
