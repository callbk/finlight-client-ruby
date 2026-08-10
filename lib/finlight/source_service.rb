# frozen_string_literal: true

module Finlight
  # Lists the news sources available through the API.
  class SourceService
    def initialize(api_client)
      @api_client = api_client
    end

    # @return [Array<Source>] all available news sources
    # @raise [ApiError] if the API request fails
    def get_sources # rubocop:disable Naming/AccessorMethodName -- mirrors the sibling clients' API
      @api_client.get("/v2/sources").map { |s| Source.from_h(s) }
    end
  end
end
