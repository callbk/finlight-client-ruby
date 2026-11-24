# frozen_string_literal: true

require "json"

module Finlight
  # WebSocket frame decoder. Internal.
  #
  # Frames are checked for `event` first (v3). A frame with only `action` is a control frame in
  # v2 form, which the server sends before the first v3 subscribe of a connection (admit, pong,
  # preempted, error). It is mapped onto the same v3 types. A v2 `sendArticle` frame is never
  # delivered as an article.
  module Frames
    Frame = Struct.new(:type, :event, :kind, :data, :raw, :v2, :fields, keyword_init: true)

    ARTICLE_KINDS = {
      StreamEventName::ARTICLE_CREATED => StreamEventKind::CREATED,
      StreamEventName::ARTICLE_UPDATED => StreamEventKind::UPDATED
    }.freeze

    module_function

    def decode(text)
      obj = parse(text)
      return Frame.new(type: :invalid, raw: obj) unless obj.is_a?(Hash)

      event = obj["event"]
      return v3(event, obj) if event.is_a?(String)

      action = obj["action"]
      return v2(action, obj) if action.is_a?(String)

      Frame.new(type: :other, kind: StreamEventKind::OTHER, raw: obj)
    end

    def parse(text)
      JSON.parse(text.to_s.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError, EncodingError
      nil
    end

    def v3(event, obj)
      data = obj["data"]
      kind = ARTICLE_KINDS[event]
      return Frame.new(type: :article, event: event, kind: kind, data: data, raw: obj) if kind

      d = data.is_a?(Hash) ? data : {}
      case event
      when StreamEventName::CONNECTION_ADMITTED then Frame.new(type: :admitted, event: event, raw: obj,
                                                               fields: admitted_fields(d))
      when StreamEventName::CONNECTION_PONG then Frame.new(type: :pong, event: event, raw: obj, fields: {})
      when StreamEventName::CONNECTION_PREEMPTED then Frame.new(type: :preempted, event: event, raw: obj,
                                                                fields: preempted_fields(d))
      when StreamEventName::CONNECTION_ERROR
        Frame.new(type: :error, event: event, raw: obj,
                  fields: { code: str(d["code"]), message: str(d["message"]), details: d["details"] })
      else
        Frame.new(type: :other, event: event, kind: StreamEventKind::OTHER, data: data, raw: obj)
      end
    end

    # Control frames in v2 form (the server sends them before the first v3 subscribe).
    def v2(action, obj)
      case action
      when "pong" then Frame.new(type: :pong, event: StreamEventName::CONNECTION_PONG, raw: obj, v2: true,
                                 fields: {})
      when "admit" then Frame.new(type: :admitted, event: StreamEventName::CONNECTION_ADMITTED, raw: obj,
                                  v2: true, fields: admitted_fields(obj))
      when "preempted" then Frame.new(type: :preempted, event: StreamEventName::CONNECTION_PREEMPTED, raw: obj,
                                      v2: true, fields: preempted_fields(obj))
      when "error"
        value = obj.key?("error") ? obj["error"] : obj["data"]
        message = value.is_a?(String) ? value : value && JSON.generate(value)[0, 200]
        Frame.new(type: :error, event: StreamEventName::CONNECTION_ERROR, raw: obj, v2: true,
                  fields: { code: nil, message: message, details: nil })
      when "sendArticle" then Frame.new(type: :legacy_article, raw: obj, v2: true)
      else Frame.new(type: :other, kind: StreamEventKind::OTHER, raw: obj, v2: true)
      end
    end

    def admitted_fields(hash)
      { lease_id: str(hash["leaseId"]), server_now: int(hash["serverNow"]), client_nonce: str(hash["clientNonce"]) }
    end

    def preempted_fields(hash)
      { reason: str(hash["reason"]), new_lease_id: str(hash["newLeaseId"]), timestamp: int(hash["timestamp"]) }
    end

    def str(value)
      value.is_a?(String) ? value : nil
    end

    def int(value)
      value.is_a?(Integer) ? value : nil
    end
  end
end
