# frozen_string_literal: true

RSpec.describe "Conformance F: forward compatibility" do
  it "F-01 #{Kit.case_titles["F-01"]}", kit_case: "F-01" do
    fx = Kit.load("fixtures/forward-compat/unknown-fields.json")
    article = Finlight::Article.decode(fx["wire"])
    expect(article.to_wire).to eq(fx["known"])
    raw = article.raw_json
    expect(raw["wordCount"]).to eq(fx["wire"]["wordCount"])
    expect(raw["source"]["name"]).to eq("Example News")
    expect(raw["events"][0]).to have_key("subtype")
    expect(article.companies[0].primary_listing.raw_json["figi"]).to eq("BBG000SYNTH1")
    expect(article.sentiment.raw_json["score"]).to eq(0.73)
  end

  it "F-02 #{Kit.case_titles["F-02"]}", kit_case: "F-02" do
    fx = Kit.load("fixtures/forward-compat/unknown-enum-values.json")
    article = Finlight::Article.decode(fx["wire"])
    expect(article.to_wire).to eq(fx["wire"])
    expect(article.source.type).to eq("wire_service")
    expect(article.sentiment.label).to eq("mixed")
    expect(article.companies[0].role).to eq("guarantor")
    event = article.events[0]
    expect([event.type, event.direction, event.importance]).to eq(%w[esg_controversy mixed extreme])
    expect(article.categories[1]).to eq("synthetic-new-category")
  end

  it "F-03 #{Kit.case_titles["F-03"]}", kit_case: "F-03" do
    fx = Kit.load("fixtures/forward-compat/envelope-keys.json")
    kinds = fx["envelopes"].map do |env|
      wire = env["wire"]
      case env["kind"]
      when "rest.search"
        page = FinlightInternal::Decode.article_page(wire)
        expect(page.articles.size).to eq(1)
        expect(page.pagination.has_more).to be(false)
      when "rest.article"
        expect(FinlightInternal::Decode.article(wire).id).to eq(wire["article"]["id"])
      when "webhook"
        event = FinlightInternal::Decode.webhook_event(wire)
        expect(event.event_id).to eq(wire["eventId"])
        expect(event.data.id).to eq(wire["data"]["id"])
        expect(event.raw_json["deliveryAttempt"]).to eq(1)
      when "ws.article"
        frame = FinlightInternal::Frames.decode(JSON.generate(wire))
        expect([frame.type, frame.kind]).to eq([:article, "created"])
        expect(Finlight::Article.decode(frame.data).id).to eq(wire["data"]["id"])
      when "ws.control"
        expect(FinlightInternal::Frames.decode(JSON.generate(wire)).type).to eq(:pong)
      else raise "unknown envelope #{env["kind"]}"
      end
      env["kind"]
    end
    expect(kinds.sort).to eq(%w[rest.article rest.search webhook ws.article ws.control])
  end

  it "F-04 #{Kit.case_titles["F-04"]}", kit_case: "F-04" do
    fx = Kit.load("fixtures/forward-compat/unknown-events-and-codes.json")
    fx["items"].each do |item|
      if item["kind"] == "webhook.event"
        expect(FinlightInternal::Decode.webhook_event(item["wire"]).event).to eq("article.retracted")
        next
      end
      mock_http.reset
      mock_http.respond({ status: item["status"], headers: item["headers"], body: item["wire"] })
      client = rest_client
      error = nil
      begin
        client.articles.search(query: "x")
      rescue Finlight::ApiError => e
        error = e
      end
      expect(mock_http.requests.size).to eq(1)
      expect(error.status).to eq(item["status"])
      expect(error.code).to eq(item["wire"]["code"])
      expect(error.request_id).to eq(item["wire"]["requestId"])
      expect(error.detail).to eq(item["wire"]["detail"])
      if item["kind"] == "problem.code"
        expect(error.class).to eq(Finlight::ApiError)
        expect(error.api_kind).to eq("other")
      else
        expect(error).to be_a(Finlight::RateLimitedError)
        expect(error.api_kind).to eq("rate_limited")
        expect(error.limit_type).to eq("daily")
      end
    end
    expect(recording_clock.sleeps).to eq([])
  end
end
