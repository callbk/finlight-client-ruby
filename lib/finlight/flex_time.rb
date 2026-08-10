# frozen_string_literal: true

require "date"

module Finlight
  # Parses the timestamp formats used by the finlight API: RFC 3339 with or
  # without zone, space-separated, and date-only. Zone-less timestamps are
  # interpreted as UTC, matching the sibling clients.
  module FlexTime
    module_function

    # @param value [String, Time, nil]
    # @return [Time, nil] the parsed time in UTC, or nil for nil input
    # @raise [Finlight::Error] if the value matches none of the known formats
    def parse(value)
      return nil if value.nil?
      return value.utc if value.is_a?(Time)

      s = value.to_s.strip
      iso_like = s.include?(" ") ? s.sub(" ", "T") : s
      DateTime.iso8601(iso_like).to_time.utc
    rescue ArgumentError, TypeError
      raise Error, "finlight: cannot parse timestamp: #{value.inspect}"
    end
  end
end
