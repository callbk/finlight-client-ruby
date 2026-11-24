# frozen_string_literal: true

RSpec.describe "models" do
  let(:wire) { Kit.load("fixtures/decode/full-article.json")["wire"] }

  it "keeps values as sent (R-MODELS-2)" do
    article = Finlight::Article.decode(wire.merge("publishedAt" => "1970-01-01T00:00:00.000Z", "summary" => "",
                                                  "firstSeenAt" => "garbage", "revisedAt" => "now",
                                                  "sentiment" => { "label" => "positive",
                                                                   "confidence" => 0.912345678 }))
    expect(article.published_at).to eq("1970-01-01T00:00:00.000Z")
    expect(article.published_at_time).to eq(Time.utc(1970))
    expect(article.summary).to eq("")
    expect(article.first_seen_at).to eq("garbage")
    expect(article.first_seen_at_time).to be_nil
    expect(article.revised_at_time).to be_nil
    expect(article.sentiment.confidence).to eq(0.912345678)
    frame = Finlight::Frames.decode('{"event":"connection.admitted","data":{"serverNow":1763932800123}}')
    expect(frame.fields[:server_now]).to eq(1_763_932_800_123)
  end

  it "parses times strictly (RFC 3339 with Z or an offset only)" do
    parse = Finlight::TimeParse.method(:parse)
    expect(parse.call("2026-11-23T21:04:05.123Z")).to eq(Time.utc(2026, 11, 23, 21, 4, 5.123r))
    expect(parse.call("2026-11-23T22:04:05+01:00")).to eq(Time.utc(2026, 11, 23, 21, 4, 5))
    ["2026-11-23T21:04:05", "2026-11-23", "1763932800", "2026-02-30T00:00:00Z", "", nil, 5,
     "2026-11-23 21:04:05Z", "2026-11-23T25:00:00Z"].each do |bad|
      expect(parse.call(bad)).to be_nil, bad.inspect
    end
  end

  it "does not coerce types" do
    expect { Finlight::Article.decode(wire.merge("sentiment" => { "label" => "positive", "confidence" => "0.95" })) }
      .to raise_error(Finlight::DecodeError) { |e| expect(e.path).to eq("$.sentiment.confidence") }
    expect { Finlight::Article.decode(wire.merge("companies" => [wire["companies"][0].merge("companyId" => "1")])) }
      .to raise_error(Finlight::DecodeError)
    expect { Finlight::Article.decode(wire.merge("source" => { "domain" => nil })) }
      .to raise_error(Finlight::DecodeError)
  end

  it "reads absent or null lists as [] and keeps gated keys absent" do
    article = Finlight::Article.decode(wire.except("media", "countries", "content", "companies")
                                           .merge("categories" => nil))
    expect([article.media, article.countries, article.categories]).to eq([[], [], []])
    expect(article.content_present?).to be(false)
    expect(article.companies).to be_nil
    out = article.to_wire
    expect(out).not_to have_key("content")
    expect(out).not_to have_key("companies")
    expect(out).not_to have_key("media")
  end

  it "is immutable and keeps the raw JSON off the wire members" do
    article = Finlight::Article.decode(wire)
    expect(article).to be_frozen
    expect(article.raw_json).to be_frozen
    expect(article.members).not_to include(:raw)
    expect { article.raw_json["id"] = "x" }.to raise_error(FrozenError)
  end
end
