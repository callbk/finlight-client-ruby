# frozen_string_literal: true

RSpec.describe "Conformance D: decode" do
  gated = %w[content sentiment companies events]

  def check_presence(article, expect_presence)
    expect_presence.each do |path, state|
      expect(Kit.presence(article, path)).to eq(state), path
      expect(Kit.helper_presence(article, path)).to eq(state), "helper for #{path}" if
        %w[content sentiment companies events].include?(path)
    end
    # companyIds only appears when companies is in the same payload; absent reads as nil, never [].
    (article.events || []).each { |event| expect(event.company_ids).to be_nil unless article.companies_present? }
  end

  def check_roundtrip(article, wire)
    expect(article.raw_json).to eq(wire)
    out = article.to_wire
    expect(out).to eq(wire)
    %w[content sentiment companies events].each do |key|
      expect(out.key?(key)).to eq(wire.key?(key))
      expect(out[key]).to be_nil if wire.key?(key) && wire[key].nil?
    end
  end

  Kit.fixtures("fixtures/decode").reject { |pair| pair.first == "D-10" }.each do |id, name|
    it "#{id} #{Kit.case_titles[id]}", kit_case: id do
      fx = Kit.load("fixtures/decode/#{name}")
      wire = fx["wire"]
      article = Finlight::Article.decode(wire)
      check_presence(article, fx["expect"]["presence"])
      check_roundtrip(article, wire)

      case id
      when "D-01"
        expect(article.media.size).to eq(3)
        expect(article.revised_at).to eq(wire["revisedAt"])
        expect(article.companies[1].primary_listing).to be_nil
        expect(article.events[0].company_ids).to eq([900_001, 900_002])
        expect(article.sentiment.confidence).to eq(0.9812)
        expect(article.available_at_time).to be_a(Time)
      when "D-02"
        expect(article.available_at).to be_nil
        gated.each { |key| expect(Kit.helper_presence(article, key)).to eq("absent") }
      when "D-03"
        expect(article.sentiment_present?).to be(true)
        expect(article.content_present?).to be(false)
      when "D-04"
        expect([article.content, article.companies, article.events]).to all(be_nil)
        expect(article.content_present?).to be(false)
        expect(article.sentiment_present?).to be(false)
      when "D-05", "D-06"
        expect(article.events_present?).to be(true)
        expect(article.companies_present?).to be(false)
        expect(article.events.map(&:company_ids)).to all(be_nil)
      when "D-07"
        expect(article.published_at).to eq("1970-01-01T00:00:00.000Z")
        expect(article.published_at_time.year).to eq(1970)
        expect(article.summary).to be_nil
        expect(article.first_seen_at).to be_nil
        expect(article.companies[0].role).to be_nil
        expect(article.companies[0].relevance).to be_nil
        expect(article.companies[0].primary_listing.ticker).to eq("LGCY")
        expect(article.events).to eq([])
        expect(article.events_present?).to be(true)
        expect([article.countries, article.categories]).to eq([[], []])
        expect(article.content_present?).to be(true)
        expect(article.content).to be_nil
      when "D-08"
        expect(article.title).to eq(wire["title"])
        expect(article.title.encoding).to eq(Encoding::UTF_8)
        expect(article.content).to eq(wire["content"])
      when "D-09"
        expect(article.sentiment.label).to be_nil
        expect(article.sentiment.confidence).to eq(wire["sentiment"]["confidence"])
        expect(article.companies).to eq([])
        expect(article.companies_present?).to be(true)
        expect(article.events[0].direction).to be_nil
        expect(article.events[0].importance).to be_nil
        expect(article.events[0].confidence).to be_nil
      when "D-11"
        expect(article.summary).to be_nil
        expect(article.content).to be_nil
        expect(article.content_present?).to be(true)
        expect(article.title).to eq(wire["title"])
      end
    end
  end

  describe "D-10 decode matrix" do
    matrix = Kit.load("fixtures/decode/matrix.json")
    it "D-10 has every sub-case", kit_case: "D-10" do
      expect(matrix["cases"].size).to eq(matrix["count"])
    end

    matrix["cases"].each do |sub|
      it "#{sub["id"]} #{sub["channel"]} include=#{sub["include"].join(",")}", kit_case: "D-10" do
        article = Finlight::Article.decode(sub["wire"])
        check_presence(article, sub["expect"]["presence"])
        check_roundtrip(article, sub["wire"])
        expect(article.available_at).to be_nil if sub["channel"] == "raw"
      end
    end
  end
end
