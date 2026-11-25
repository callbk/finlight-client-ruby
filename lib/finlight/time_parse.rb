# frozen_string_literal: true

require "date"

module Finlight
  # Strict RFC 3339 parsing. Internal.
  module TimeParse
    PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/

    module_function

    # @return [Time, nil] the instant in UTC, nil for anything that is not RFC 3339 with Z or an offset
    def parse(value)
      return nil unless value.is_a?(String)

      m = PATTERN.match(value)
      return nil unless m

      year, month, day, hour, minute, second = m.captures[0, 6].map(&:to_i)
      return nil unless Date.valid_date?(year, month, day)
      return nil if hour > 23 || minute > 59 || second > 60

      offset = m[8] == "Z" ? "+00:00" : m[8]
      off_h = offset[1, 2].to_i
      off_m = offset[4, 2].to_i
      return nil if off_h > 23 || off_m > 59

      fraction = m[7] ? Rational(m[7][1..].to_i, 10**(m[7].length - 1)) : 0
      Time.new(year, month, day, hour, minute, second + fraction, offset).utc
    rescue ArgumentError, RangeError
      nil
    end

    # Formats a Time as UTC ISO 8601 with milliseconds and Z, independent of the locale.
    def format(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end
  end

  # Internal: not part of the public API (only the sdk-style name table is), may change in any release.
  private_constant :TimeParse
end
