# frozen_string_literal: true

# finlight API v3 client: REST (articles, companies, sources), real-time streams over WebSocket
# and webhook verification.
#
#   require "finlight"
#   client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"))
module Finlight
end

require_relative "finlight/version"
require_relative "finlight/vocab"
require_relative "finlight/errors"
require_relative "finlight/time_parse"
require_relative "finlight/models"
require_relative "finlight/config"
require_relative "finlight/params"
require_relative "finlight/http"
require_relative "finlight/articles"
require_relative "finlight/companies"
require_relative "finlight/frames"
require_relative "finlight/transport"
require_relative "finlight/stream"
require_relative "finlight/webhooks"
require_relative "finlight/client_impl"
