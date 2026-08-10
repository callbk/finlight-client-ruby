# frozen_string_literal: true

module Finlight
  # Converts idiomatic snake_case Ruby keyword arguments into the camelCase
  # JSON wire format, omitting unset (nil) fields. Keys that are already
  # camelCase pass through unchanged.
  module Params
    module_function

    # @param params [Hash]
    # @return [Hash{String => Object}]
    def normalize(params)
      params.each_with_object({}) do |(key, value), out|
        next if value.nil?

        out[camelize(key)] = value
      end
    end

    # page_size -> pageSize, exclude_sources -> excludeSources, from -> from
    def camelize(key)
      key.to_s.gsub(/_([a-z0-9])/) { Regexp.last_match(1).upcase }
    end
  end
end
