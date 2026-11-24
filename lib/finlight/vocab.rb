# frozen_string_literal: true

module Finlight
  # Vocabularies are open: a value is a plain String, the constants name the values known today
  # and ALL lists them. Unknown values from newer servers are kept as sent; compare by String.

  # Values of `include`.
  module IncludeBlock
    CONTENT = "content"
    COMPANIES = "companies"
    EVENTS = "events"
    ALL = [CONTENT, COMPANIES, EVENTS].freeze
  end

  # Values of `orderBy`.
  module OrderBy
    PUBLISHED_AT = "publishedAt"
    FIRST_SEEN_AT = "firstSeenAt"
    REVISED_AT = "revisedAt"
    AVAILABLE_AT = "availableAt"
    ALL = [PUBLISHED_AT, FIRST_SEEN_AT, REVISED_AT, AVAILABLE_AT].freeze
  end

  # Values of `order`.
  module SortOrder
    ASC = "asc"
    DESC = "desc"
    ALL = [ASC, DESC].freeze
  end

  # Values of a company's `role` (and of the `roles` filter).
  module CompanyRole
    ACQUIRER = "acquirer"
    TARGET = "target"
    SELLER = "seller"
    DEFENDANT = "defendant"
    SUBJECT = "subject"
    COUNTERPARTY = "counterparty"
    SUPPLIER = "supplier"
    CUSTOMER = "customer"
    COMPETITOR = "competitor"
    MENTIONED = "mentioned"
    ALL = [ACQUIRER, TARGET, SELLER, DEFENDANT, SUBJECT, COUNTERPARTY, SUPPLIER, CUSTOMER, COMPETITOR,
           MENTIONED].freeze
  end

  # Values of an event's `type` (and of the `eventTypes` filter).
  module EventType
    EARNINGS = "earnings"
    GUIDANCE = "guidance"
    MNA = "mna"
    IPO_LISTING = "ipo_listing"
    CAPITAL_ACTION = "capital_action"
    RATING_ACTION = "rating_action"
    MANAGEMENT_CHANGE = "management_change"
    LEGAL = "legal"
    REGULATORY = "regulatory"
    BANKRUPTCY_DISTRESS = "bankruptcy_distress"
    PRODUCT_PARTNERSHIP = "product_partnership"
    INVESTMENT_EXPANSION = "investment_expansion"
    OPERATIONAL_INCIDENT = "operational_incident"
    LABOR_RESTRUCTURING = "labor_restructuring"
    MACRO = "macro"
    GEOPOLITICS = "geopolitics"
    ALL = [EARNINGS, GUIDANCE, MNA, IPO_LISTING, CAPITAL_ACTION, RATING_ACTION, MANAGEMENT_CHANGE, LEGAL,
           REGULATORY, BANKRUPTCY_DISTRESS, PRODUCT_PARTNERSHIP, INVESTMENT_EXPANSION, OPERATIONAL_INCIDENT,
           LABOR_RESTRUCTURING, MACRO, GEOPOLITICS].freeze
  end

  # Values of an event's `direction`.
  module EventDirection
    POSITIVE = "positive"
    NEGATIVE = "negative"
    NEUTRAL = "neutral"
    UNCLEAR = "unclear"
    ALL = [POSITIVE, NEGATIVE, NEUTRAL, UNCLEAR].freeze
  end

  # Values of an event's `importance` (and of `minImportance`), ordered from low to critical.
  module Importance
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"
    ALL = [LOW, MEDIUM, HIGH, CRITICAL].freeze
  end

  # Values of `sentiment.label`.
  module SentimentLabel
    POSITIVE = "positive"
    NEGATIVE = "negative"
    NEUTRAL = "neutral"
    ALL = [POSITIVE, NEGATIVE, NEUTRAL].freeze
  end

  # Values of `source.type`, `Source#type` and the filters `source_types` and `exclude_source_types`
  # (search and both streams). `source.type` is nil when the source is not classified.
  module SourceType
    NEWSWIRE = "newswire"
    PRESS_RELEASE = "press_release"
    FINANCIAL_MEDIA = "financial_media"
    GENERAL_MEDIA = "general_media"
    AGGREGATOR = "aggregator"
    BLOG = "blog"
    GOVERNMENT = "government"
    ALL = [NEWSWIRE, PRESS_RELEASE, FINANCIAL_MEDIA, GENERAL_MEDIA, AGGREGATOR, BLOG, GOVERNMENT].freeze
  end

  # Names of WebSocket events.
  module StreamEventName
    ARTICLE_CREATED = "article.created"
    ARTICLE_UPDATED = "article.updated"
    CONNECTION_ADMITTED = "connection.admitted"
    CONNECTION_PONG = "connection.pong"
    CONNECTION_PREEMPTED = "connection.preempted"
    CONNECTION_ERROR = "connection.error"
    ARTICLE_EVENTS = [ARTICLE_CREATED, ARTICLE_UPDATED].freeze
    CONNECTION_EVENTS = [CONNECTION_ADMITTED, CONNECTION_PONG, CONNECTION_PREEMPTED, CONNECTION_ERROR].freeze
    ALL = (ARTICLE_EVENTS + CONNECTION_EVENTS).freeze
  end

  # Codes of `connection.error`.
  module ConnectionErrorCode
    PING_ON_DEFAULT_ROUTE = "PING_ON_DEFAULT_ROUTE"
    HANDSHAKE_FAILED = "HANDSHAKE_FAILED"
    VALIDATION_FAILED = "VALIDATION_FAILED"
    SEARCH_FAILED = "SEARCH_FAILED"
    INTERNAL_ERROR = "INTERNAL_ERROR"
    ALL = [PING_ON_DEFAULT_ROUTE, HANDSHAKE_FAILED, VALIDATION_FAILED, SEARCH_FAILED, INTERNAL_ERROR].freeze
  end

  # Reasons of `connection.preempted`.
  module PreemptReason
    CONNECTION_LIMIT = "connection_limit"
    QUOTA_EXCEEDED = "quota_exceeded"
    ALL = [CONNECTION_LIMIT, QUOTA_EXCEEDED].freeze
  end

  # Names of webhook events.
  module WebhookEventName
    ARTICLE_CREATED = "article.created"
    ARTICLE_UPDATED = "article.updated"
    ALL = [ARTICLE_CREATED, ARTICLE_UPDATED].freeze
  end

  # Problem codes of REST errors. TYPES maps each code to its problem type URL.
  module ProblemCode
    VALIDATION_FAILED = "VALIDATION_FAILED"
    CURSOR_INVALID = "CURSOR_INVALID"
    CURSOR_MISMATCH = "CURSOR_MISMATCH"
    UNAUTHORIZED = "UNAUTHORIZED"
    FORBIDDEN = "FORBIDDEN"
    NOT_FOUND = "NOT_FOUND"
    RATE_LIMITED = "RATE_LIMITED"
    INTERNAL_ERROR = "INTERNAL_ERROR"
    ALL = [VALIDATION_FAILED, CURSOR_INVALID, CURSOR_MISMATCH, UNAUTHORIZED, FORBIDDEN, NOT_FOUND,
           RATE_LIMITED, INTERNAL_ERROR].freeze
    TYPES = ALL.to_h { |code| [code, "https://docs.finlight.me/errors/#{code.downcase.tr("_", "-")}"] }.freeze
  end

  # Values of `limitType` on a 429. UNKNOWN is what the SDK reports when it cannot tell.
  module RateLimitType
    MONTHLY = "monthly"
    BURST = "burst"
    UNKNOWN = "unknown"
    ALL = [MONTHLY, BURST].freeze
  end

  # Kinds of stream elements.
  module StreamEventKind
    CREATED = "created"
    UPDATED = "updated"
    OTHER = "other"
    ALL = [CREATED, UPDATED, OTHER].freeze
  end

  # Reasons passed to on_reconnect.
  module ReconnectReason
    ROTATION = "rotation"
    WATCHDOG = "watchdog"
    CLOSED = "closed"
    HANDSHAKE_FAILED = "handshake_failed"
    SEARCH_FAILED = "search_failed"
    DIAL_FAILED = "dial_failed"
    DIAL_REFUSED = "dial_refused"
    CONNECTION_LIMIT = "connection_limit"
    RATE_LIMITED = "rate_limited"
    QUOTA_EXCEEDED = "quota_exceeded"
    ALL = [ROTATION, WATCHDOG, CLOSED, HANDSHAKE_FAILED, SEARCH_FAILED, DIAL_FAILED, DIAL_REFUSED,
           CONNECTION_LIMIT, RATE_LIMITED, QUOTA_EXCEEDED].freeze
  end
end
