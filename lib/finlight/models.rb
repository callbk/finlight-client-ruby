# frozen_string_literal: true

require "json"

module Finlight
  # Shared decoding for the wire models. Internal.
  #
  # Every wire key maps to exactly one member (snake_case). A model keeps the JSON it was read
  # from (deep-frozen) for {WireModel#raw_json} and to tell an absent key from null. Unknown keys
  # are ignored. Only required keys and present values of the wrong JSON type fail a decode.
  module WireModel
    # Field kinds:
    #   :str, :str!   String (! = required)
    #   :num          Numeric (never true/false)
    #   :int, :int!   Integer
    #   :bool         true/false
    #   :strs         Array<String>, absent or null reads as []
    #   :strs?        Array<String>, absent reads as nil
    #   :ints?        Array<Integer>, absent reads as nil
    #   Class / [Class, :required] / [Class, :list] / [Class, :list?]   nested models
    Field = Struct.new(:wire, :member, :kind, :model)

    def self.included(base)
      base.extend(ClassMethods)
    end

    # Deep-freezes a parsed JSON value.
    def self.deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }.freeze
      when Array then value.each { |v| deep_freeze(v) }.freeze
      else value.freeze
      end
    end

    def self.deep_copy(value)
      case value
      when Hash then value.to_h { |k, v| [k.dup.freeze, deep_copy(v)] }
      when Array then value.map { |v| deep_copy(v) }
      when String then value.dup
      else value
      end
    end

    def self.type_name(value)
      case value
      when nil then "null"
      when true, false then "boolean"
      when Integer, Float then "number"
      when String then "string"
      when Array then "array"
      when Hash then "object"
      else value.class.name
      end
    end

    module ClassMethods
      def wire_fields
        @wire_fields ||= []
      end

      # Declares the wire keys of the model, in wire order.
      def fields(spec)
        spec.each do |wire, kind|
          model = nil
          if kind.is_a?(Array)
            model, kind = kind
            kind = :"model_#{kind}"
          elsif kind.is_a?(Class)
            model = kind
            kind = :model
          end
          wire_fields << Field.new(wire, snake(wire).to_sym, kind, model)
        end
      end

      def snake(name)
        name.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
      end

      # Reads a model from parsed JSON. Raises DecodeError with the JSON path of the bad value.
      def decode(json, path = "$")
        unless json.is_a?(Hash)
          raise DecodeError.new("#{path}: expected an object, got #{WireModel.type_name(json)}",
                                path: path, raw: json)
        end

        values = {}
        wire_fields.each do |field|
          present = json.key?(field.wire)
          values[field.member] = read_field(field, json[field.wire], present, "#{path}.#{field.wire}")
        end
        raw = WireModel.deep_freeze(WireModel.deep_copy(json))
        new(**values, __raw: raw)
      end

      private

      def read_field(field, value, present, path)
        kind = field.kind
        required = kind.to_s.end_with?("!") || kind == :model_required
        if value.nil?
          raise DecodeError.new("#{path}: required key is #{present ? "null" : "missing"}", path: path) if required
          return [].freeze if %i[strs model_list].include?(kind)

          return nil
        end

        case kind
        when :str, :str! then check(value, path, "string") { value.is_a?(String) }.dup.freeze
        when :num then check(value, path, "number") { value.is_a?(Numeric) }
        when :int, :int! then check(value, path, "integer") { value.is_a?(Integer) }
        when :bool then check(value, path, "boolean") { [true, false].include?(value) }
        when :strs, :strs? then list(value, path) { |v, p| check(v, p, "string") { v.is_a?(String) }.dup.freeze }
        when :ints? then list(value, path) { |v, p| check(v, p, "integer") { v.is_a?(Integer) } }
        when :model, :model_required then field.model.decode(value, path)
        when :model_list, :model_list? then list(value, path) { |v, p| field.model.decode(v, p) }
        else raise ArgumentError, "unknown field kind #{kind}"
        end
      end

      def check(value, path, want)
        return value if yield

        raise DecodeError.new("#{path}: expected #{want}, got #{WireModel.type_name(value)}", path: path, raw: value)
      end

      def list(value, path)
        unless value.is_a?(Array)
          raise DecodeError.new("#{path}: expected an array, got #{WireModel.type_name(value)}",
                                path: path, raw: value)
        end

        value.each_with_index.map { |v, i| yield(v, "#{path}[#{i}]") }.freeze
      end
    end

    def initialize(__raw: nil, **members)
      @__raw_json = __raw
      super(**members)
    end

    # @return [Hash] the JSON object this model was read from (deep-frozen), unknown keys included
    def raw_json
      @__raw_json
    end

    # Writes the model back as a JSON object: absent keys stay absent, null stays null,
    # unknown keys are left out.
    # @return [Hash]
    def to_wire
      self.class.wire_fields.each_with_object({}) do |field, out|
        value = public_send(field.member)
        present = @__raw_json ? @__raw_json.key?(field.wire) : !value.nil?
        next unless present

        out[field.wire] = case value
                          when WireModel then value.to_wire
                          when Array then value.map { |v| v.is_a?(WireModel) ? v.to_wire : v }
                          else value
                          end
      end
    end
  end

  # Adds `<name>_time` readers that parse a timestamp member strictly (RFC 3339), nil when unreadable.
  module TimeReaders
    def time_readers(*names)
      names.each do |name|
        define_method(:"#{name}_time") { TimeParse.parse(public_send(name)) }
      end
    end
  end

  # `source` of an article: `{domain, type}`.
  ArticleSource = Data.define(:domain, :type) do
    include WireModel

    fields("domain" => :str!, "type" => :str)
  end

  # One image of an article.
  Media = Data.define(:url) do
    include WireModel

    fields("url" => :str)
  end

  # `sentiment` of an article: `{label, confidence}`. Both can be nil.
  Sentiment = Data.define(:label, :confidence) do
    include WireModel

    fields("label" => :str, "confidence" => :num)
  end

  # A listing: `primaryListing` of a company, or an entry of CompanyRecord#listings
  # (only those carry `active`).
  Listing = Data.define(:ticker, :mic, :country, :active) do
    include WireModel

    fields("ticker" => :str, "mic" => :str, "country" => :str, "active" => :bool)
  end

  # A company tagged on an article.
  Company = Data.define(:company_id, :name, :isin, :primary_listing, :confidence, :role, :relevance) do
    include WireModel

    fields("companyId" => :int!, "name" => :str!, "isin" => :str, "primaryListing" => Listing,
           "confidence" => :num, "role" => :str, "relevance" => :num)
  end

  # An event on an article. `company_ids` is nil when the key was not sent (it is only sent when
  # `companies` is in the same payload).
  EventTag = Data.define(:type, :direction, :importance, :confidence, :company_ids) do
    include WireModel

    fields("type" => :str!, "direction" => :str, "importance" => :str, "confidence" => :num,
           "companyIds" => :ints?)
  end

  # An article, the same in REST, WebSocket and webhooks.
  #
  # Three states for the gated keys: absent (not requested, not entitled, or raw), null, or a value.
  # `content` and `sentiment`: nil plus {#content_present?} / {#sentiment_present?}.
  # `companies` and `events`: nil means absent, [] means tagged with nothing.
  Article = Data.define(:id, :link, :source, :title, :summary, :language, :media, :published_at,
                        :first_seen_at, :revised_at, :available_at, :countries, :categories, :content,
                        :sentiment, :companies, :events) do
    include WireModel
    extend TimeReaders

    fields("id" => :str!, "link" => :str!, "source" => [ArticleSource, :required], "title" => :str!,
           "summary" => :str, "language" => :str, "media" => [Media, :list], "publishedAt" => :str,
           "firstSeenAt" => :str, "revisedAt" => :str, "availableAt" => :str, "countries" => :strs,
           "categories" => :strs, "content" => :str, "sentiment" => Sentiment,
           "companies" => [Company, :list?], "events" => [EventTag, :list?])
    time_readers :published_at, :first_seen_at, :revised_at, :available_at

    # @return [Boolean] whether the `content` key was sent (null counts as sent)
    def content_present?
      raw_json ? raw_json.key?("content") : !content.nil?
    end

    # @return [Boolean] whether the `sentiment` key was sent (null counts as sent)
    def sentiment_present?
      raw_json ? raw_json.key?("sentiment") : !sentiment.nil?
    end

    # @return [Boolean] whether `companies` was sent ([] counts as sent)
    def companies_present?
      !companies.nil?
    end

    # @return [Boolean] whether `events` was sent ([] counts as sent)
    def events_present?
      !events.nil?
    end
  end

  # ETag data of a record from companies.get.
  CacheInfo = Data.define(:etag, :cache_control, :not_modified)

  # A company from the companies endpoints.
  CompanyRecord = Data.define(:company_id, :name, :country, :sector, :industry, :isins, :primary_listing,
                              :listings, :updated_at) do
    include WireModel
    extend TimeReaders

    fields("companyId" => :int!, "name" => :str!, "country" => :str, "sector" => :str, "industry" => :str,
           "isins" => :strs, "primaryListing" => Listing, "listings" => [Listing, :list], "updatedAt" => :str)
    time_readers :updated_at

    def initialize(__cache_info: nil, **rest)
      @__cache_info = __cache_info
      super(**rest)
    end

    # @return [CacheInfo, nil] ETag and Cache-Control of the answer (companies.get only)
    def cache_info
      @__cache_info
    end

    # @api private
    def __with_cache_info(info)
      self.class.new(**to_h, __raw: raw_json, __cache_info: info)
    end
  end

  # A source from sources.list. `has_content` is nil when the plan may not know it.
  Source = Data.define(:domain, :name, :type, :is_default, :is_custom, :country, :languages, :has_content) do
    include WireModel

    fields("domain" => :str!, "name" => :str, "type" => :str, "isDefault" => :bool, "isCustom" => :bool,
           "country" => :str, "languages" => :strs?, "hasContent" => :bool)
  end

  # `pagination` of a search page.
  Pagination = Data.define(:limit, :returned, :has_more, :next_cursor) do
    include WireModel

    fields("limit" => :int, "returned" => :int, "hasMore" => :bool, "nextCursor" => :str)
  end

  # An entry of a list that could not be read: its index, the raw JSON and the reason.
  SkippedEntry = Data.define(:index, :raw, :reason)

  # One page of articles.search.
  ArticlePage = Data.define(:articles, :pagination, :skipped)

  # A list of entries plus the entries that could not be read (`skipped`).
  class EntryList
    include Enumerable

    # @return [Array<SkippedEntry>]
    attr_reader :skipped

    def initialize(items, skipped)
      @items = items.freeze
      @skipped = skipped.freeze
      freeze
    end

    def each(&)
      return enum_for(:each) unless block_given?

      @items.each(&)
      self
    end

    def [](index)
      @items[index]
    end

    def size
      @items.size
    end
    alias length size

    def empty?
      @items.empty?
    end

    def to_a
      @items.dup
    end

    def ==(other)
      to_a == (other.is_a?(EntryList) ? other.to_a : other)
    end

    def inspect
      "#<#{self.class.name} #{@items.inspect} skipped=#{@skipped.size}>"
    end
  end

  # Result of companies.search and companies.get_many.
  class CompanyList < EntryList; end

  # Result of sources.list.
  class SourceList < EntryList; end

  # One element of a stream.
  #
  # @!attribute kind [String] "created", "updated" or "other" (an event this SDK does not know)
  # @!attribute event [String] the wire name, e.g. "article.created"
  # @!attribute data [Article, nil] nil for kind "other"
  StreamEvent = Data.define(:kind, :event, :data) do
    def initialize(kind:, event:, data:, __raw: nil)
      @__raw_json = __raw
      super(kind: kind, event: event, data: data)
    end

    # @return [Hash] the whole frame as JSON
    def raw_json
      @__raw_json
    end
  end

  # Passed to on_admitted for every `connection.admitted`. Admission comes before the server checks
  # the subscribe: it does not mean the subscribe was accepted.
  AdmittedInfo = Data.define(:lease_id, :server_now, :client_nonce)

  # Passed to on_reconnect after every new connection except the first. `last_seen_at` is the latest
  # availableAt (fallback firstSeenAt; raw: firstSeenAt) seen, nil when nothing came yet.
  ReconnectInfo = Data.define(:last_seen_at, :reason, :connection)

  # Passed to on_quota_wait when the monthly WebSocket quota is used up. `error` is the PreemptedError
  # or the ForbiddenError of the refused dial; `next_attempt_in` is in seconds; `attempt` starts at 1.
  QuotaWaitInfo = Data.define(:error, :next_attempt_in, :attempt)

  # A verified v3 webhook.
  WebhookEvent = Data.define(:event_id, :event, :occurred_at, :payload_version, :subscription_id,
                             :changed_fields, :data) do
    include WireModel
    extend TimeReaders

    fields("eventId" => :str!, "event" => :str!, "occurredAt" => :str, "payloadVersion" => :num,
           "subscriptionId" => :str, "changedFields" => :strs?, "data" => [Article, :required])
    time_readers :occurred_at

    # @return [Boolean] true for the dashboard test webhook (eventId starts with "evt_test")
    def test?
      event_id.start_with?("evt_test")
    end
  end

  # A correctly signed webhook body that is not payloadVersion 3 (an old v2 body). Not an error:
  # answer it with 2xx and keep `raw`.
  #
  # @!attribute detected_version [Integer] the version by the server's rule (always 2 here)
  # @!attribute payload_version [Object, nil] the raw payloadVersion as received
  # @!attribute payload_version_present [Boolean] whether the key was sent
  # @!attribute raw [Hash] the parsed JSON
  # @!attribute link [String, nil] the article link, when readable
  WrongPayloadVersion = Data.define(:detected_version, :payload_version, :payload_version_present, :raw, :link) do
    # @return [Hash] the parsed JSON (same as #raw)
    def raw_json
      raw
    end
  end

  # Decoding helpers for envelopes. Internal.
  module Decode
    module_function

    def parse(body, what)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      JSON.parse(text)
    rescue JSON::ParserError, EncodingError => e
      raise DecodeError.new("#{what} is not valid JSON: #{e.class.name}", path: "$")
    end

    # Reads a list; broken entries are skipped (logged, kept in `skipped`).
    def entries(list, model, path, logger)
      unless list.is_a?(Array)
        raise DecodeError.new("#{path}: expected an array, got #{WireModel.type_name(list)}", path: path, raw: list)
      end

      items = []
      skipped = []
      list.each_with_index do |raw, index|
        items << model.decode(raw, "#{path}[#{index}]")
      rescue DecodeError => e
        logger&.warn("finlight") { "skipped an unreadable entry: #{e.message}" }
        skipped << SkippedEntry.new(index: index, raw: WireModel.deep_freeze(WireModel.deep_copy(raw)),
                                    reason: e.message)
      end
      [items, skipped]
    end

    def envelope(json, key)
      return json[key] if json.is_a?(Hash) && json.key?(key)

      raise DecodeError.new("response has no #{key.inspect} key", path: "$.#{key}")
    end

    def article_page(json, logger = nil)
      articles, skipped = entries(envelope(json, "articles"), Article, "$.articles", logger)
      pagination = Pagination.decode(envelope(json, "pagination"), "$.pagination")
      ArticlePage.new(articles: articles.freeze, pagination: pagination, skipped: skipped.freeze)
    end

    def article(json)
      Article.decode(envelope(json, "article"), "$.article")
    end

    def webhook_event(json)
      WebhookEvent.decode(json)
    end
  end

  # Internal: not part of the public API (only the sdk-style name table is), may change in any release.
  private_constant :WireModel, :TimeReaders, :EntryList, :Decode
end
