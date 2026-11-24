# frozen_string_literal: true

require "date"
require "json"

module Finlight
  # Shape checks and serialization of request parameters. Internal.
  #
  # The set of keys is fixed; values of vocabularies stay open (any String). Only the keys the
  # caller set are sent, with the exact wire name; nil means "not set".
  module Params
    module_function

    def fail!(message, param)
      raise ValidationError.new(message, param: param)
    end

    def reject_unknown!(unknown, method)
      return if unknown.nil? || unknown.empty?

      key = unknown.keys.first.to_s
      fail!("#{method} does not take #{key.inspect}", key)
    end

    def string!(value, name, max: nil, non_empty: false)
      fail!("#{name} must be a String", name) unless value.is_a?(String)
      fail!("#{name} must not be empty", name) if non_empty && value.empty?
      fail!("#{name} must be at most #{max} characters", name) if max && value.length > max
      value
    end

    def strings!(value, name, non_empty: false)
      fail!("#{name} must be an Array of Strings", name) unless value.is_a?(Array) && value.all?(String)
      fail!("#{name} must not be empty", name) if non_empty && value.empty?
      value.map { |v| v.dup.freeze }.freeze
    end

    def bool!(value, name)
      fail!("#{name} must be true or false", name) unless [true, false].include?(value)
      value
    end

    def limit!(value, name = "limit")
      fail!("#{name} must be an Integer from 1 to 100", name) unless value.is_a?(Integer) && value.between?(1, 100)
      value
    end

    def relevance!(value, name)
      fail!("#{name} must be a number from 0 to 1", name) unless value.is_a?(Numeric) && value.between?(0, 1)
      value
    end

    # Returns the include list, or nil when empty (an empty include is left out).
    def include!(value, name = "include")
      list = strings!(value, name)
      fail!("#{name} takes at most 3 values", name) if list.size > 3
      list.empty? ? nil : list
    end

    # Date and time: a Time (or DateTime) goes out as UTC ISO 8601 with milliseconds and Z,
    # a Date as YYYY-MM-DD, a String unchanged.
    def time!(value, name)
      case value
      when String then value.dup.freeze
      when Time then TimeParse.format(value)
      when DateTime then TimeParse.format(value.to_time)
      when Date then value.strftime("%Y-%m-%d")
      else fail!("#{name} must be a Time, Date or String", name)
      end
    end

    def ids!(value, name = "ids")
      unless value.is_a?(Array) && value.all? { |v| v.is_a?(Integer) && v >= 1 } && value.size.between?(1, 10)
        fail!("#{name} must be an Array of 1 to 10 Integers >= 1", name)
      end
      value.dup.freeze
    end

    # Percent-encodes one query value or path segment (RFC 3986 unreserved characters stay).
    def escape(value)
      value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |c| format("%%%02X", c.ord) }
    end

    def query_string(pairs)
      pairs.map { |k, v| "#{escape(k)}=#{escape(v)}" }.join("&")
    end

    # JSON text of a request body; {} for no parameters.
    def json(hash)
      JSON.generate(hash)
    end

    SEARCH_KEYS = {
      query: "query", sources: "sources", opt_in_sources: "optInSources", exclude_sources: "excludeSources",
      from: "from", to: "to", languages: "languages", tickers: "tickers", countries: "countries",
      categories: "categories", has_content: "hasContent", roles: "roles", min_relevance: "minRelevance",
      event_types: "eventTypes", event_directions: "eventDirections", min_importance: "minImportance",
      sectors: "sectors", company_countries: "companyCountries", exchanges: "exchanges", order_by: "orderBy",
      order: "order", limit: "limit", cursor: "cursor", include: "include"
    }.freeze

    LIST_KEYS = %i[sources opt_in_sources exclude_sources tickers countries categories roles event_types
                   event_directions sectors company_countries exchanges].freeze
    STRING_KEYS = %i[query min_importance order_by order cursor].freeze

    # Body of POST /v3/articles/search from the keywords the caller set.
    def search_body(args)
      body = {}
      args.each do |key, value|
        next if value.nil?

        wire = SEARCH_KEYS.fetch(key)
        body[wire] = search_value(key, value, key.to_s)
        body.delete(wire) if body[wire].nil?
      end
      body
    end

    def search_value(key, value, name)
      case key
      when *LIST_KEYS then strings!(value, name)
      when *STRING_KEYS then string!(value, name)
      when :languages then strings!(value, name, non_empty: true)
      when :from, :to then time!(value, name)
      when :has_content then bool!(value, name)
      when :min_relevance then relevance!(value, name)
      when :limit then limit!(value, name)
      when :include then include!(value, name)
      end
    end

    STREAM_KEYS = {
      query: "query", sources: "sources", exclude_sources: "excludeSources", opt_in_sources: "optInSources",
      language: "language", tickers: "tickers", countries: "countries", categories: "categories",
      exclude_empty_content: "excludeEmptyContent", include_updates: "includeUpdates", include: "include"
    }.freeze
    RAW_STREAM_KEYS = %i[query sources exclude_sources language include_updates].freeze

    # Subscribe frame, built from a fixed list of keys (never a copy of the caller's object).
    def subscribe_frame(args, raw:)
      frame = { "payloadVersion" => PAYLOAD_VERSION }
      args.each do |key, value|
        next if value.nil?

        fail!("raw streams do not take #{key}", key.to_s) if raw && !RAW_STREAM_KEYS.include?(key)

        wire = STREAM_KEYS.fetch(key)
        name = key.to_s
        frame[wire] = case key
                      when :query, :language then string!(value, name)
                      when :sources, :exclude_sources, :opt_in_sources, :tickers, :countries, :categories
                        strings!(value, name)
                      when :exclude_empty_content, :include_updates then bool!(value, name)
                      when :include then include!(value, name)
                      end
        frame.delete(wire) if frame[wire].nil?
      end
      frame.freeze
    end
  end
end
