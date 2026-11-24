# frozen_string_literal: true

RSpec.describe "Conformance V: vocabulary" do
  it "V-01 known constants equal vocab.json", kit_case: "V-01" do
    vocab = Kit.load("vocab.json")
    req = vocab["request"]
    resp = vocab["response"]
    ws = vocab["websocket"]
    expect(Finlight::PAYLOAD_VERSION).to eq(vocab["payloadVersion"])

    expect(Finlight::IncludeBlock::ALL).to eq(req["include"]["values"])
    expect(Finlight::OrderBy::ALL).to eq(req["orderBy"]["values"])
    expect(Finlight::SortOrder::ALL).to eq(req["order"]["values"])
    expect(Finlight::CompanyRole::ALL).to eq(req["roles"]["values"]).and eq(resp["roles"]["values"])
    expect(Finlight::EventType::ALL).to eq(req["eventTypes"]["values"]).and eq(resp["eventTypes"]["values"])
    expect(Finlight::EventDirection::ALL).to eq(req["eventDirections"]["values"])
      .and eq(resp["eventDirections"]["values"])
    expect(Finlight::Importance::ALL).to eq(req["minImportance"]["values"]).and eq(resp["importance"]["values"])
    expect(Finlight::SentimentLabel::ALL).to eq(resp["sentimentLabels"]["values"])
    expect(Finlight::SourceType::ALL).to eq(req["sourceTypes"]["values"])
      .and eq(req["excludeSourceTypes"]["values"]).and eq(resp["sourceTypes"]["values"])

    expect(Finlight::StreamEventName::ALL).to eq(ws["events"]["values"])
    expect(Finlight::StreamEventName::ARTICLE_EVENTS).to eq(ws["articleEvents"]["values"])
    expect(Finlight::StreamEventName::CONNECTION_EVENTS).to eq(ws["connectionEvents"]["values"])
    expect(Finlight::ConnectionErrorCode::ALL).to eq(ws["connectionErrorCodes"]["values"])
    expect(Finlight::PreemptReason::ALL).to eq(ws["preemptReasons"]["values"])
    expect(Finlight::WebhookEventName::ALL).to eq(vocab["webhook"]["events"]["values"])
    expect(Finlight::ProblemCode::ALL.map { |c| { "code" => c, "type" => Finlight::ProblemCode::TYPES[c] } })
      .to eq(vocab["problemCodes"]["values"])
    expect(Finlight::RateLimitType::ALL).to eq(vocab["limitTypes"]["values"])

    # Every constant is a String, never a Symbol.
    [Finlight::IncludeBlock, Finlight::EventType, Finlight::CompanyRole, Finlight::StreamEventName].each do |mod|
      expect(mod::ALL).to all(be_a(String))
    end

    defaults = Finlight::Config.new(api_key: "k")
    expect(defaults.ping_interval * 1000).to eq(ws["heartbeatMs"])
    expect(defaults.watchdog_timeout * 1000).to eq(ws["staleMs"])
    expect(defaults.rotation_interval * 1000).to be < ws["maxLifetimeMs"]

    # Response vocabularies are open: unknown strings survive decoding unchanged.
    article = Finlight::Article.decode(Kit.load("fixtures/forward-compat/unknown-enum-values.json")["wire"])
    expect(article.events[0].type).to eq("esg_controversy")
    expect(Finlight::EventType::ALL).not_to include(article.events[0].type)
  end
end
