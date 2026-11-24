# frozen_string_literal: true

RSpec.describe "Conformance P: pagination" do
  def script(responses)
    mock_http.respond(*responses.map { |r| { status: r["status"], headers: r["headers"], body: r["body"] } })
  end

  it "P-01 #{Kit.case_titles["P-01"]}", kit_case: "P-01" do
    fx = Kit.load("fixtures/pagination/three-pages.json")
    script(fx["steps"].map { |s| s["response"] })
    args = Kit.snake_args(fx["sdk"]["args"])
    result = rest_client.articles.search_all(**args)
    args[:sources] << "mutated.example.org" # the body is frozen at call time
    ids = result.map(&:id)
    expected = fx["steps"].flat_map { |s| s["response"]["body"]["articles"].map { |a| a["id"] } }
    expect(ids).to eq(expected)
    expect(ids.size).to eq(5)
    sent = mock_http.requests.map(&:body)
    expect(sent.size).to eq(3)
    expect(sent.map { |b| JSON.parse(b) }).to eq(fx["steps"].map { |s| s["request"]["body"] })
    sent[1..].zip(fx["steps"][1..]).each do |body, step|
      expect(body).to eq("#{sent[0][0..-2]},\"cursor\":#{JSON.generate(step["request"]["body"]["cursor"])}}")
    end
    expect(result.pages_fetched).to eq(3)
    expect(result.next_cursor).to be_nil
    expect(result.truncated?).to be(false)
    expect { result.to_a }.to raise_error(Finlight::ValidationError)
    ids_sent = mock_http.requests.map { |r| r.header("X-Request-Id") }
    expect(ids_sent.uniq.size).to eq(3)
    expect(sent.map { |b| JSON.parse(b) }).to all(satisfy { |b| !b.key?("to") && !b.key?("languages") })
  end

  it "P-01 max_pages stops the walk and keeps the cursor", kit_case: "P-01" do
    fx = Kit.load("fixtures/pagination/three-pages.json")
    script(fx["steps"].map { |s| s["response"] })
    log = StringIO.new
    client = rest_client(logger: Logger.new(log))
    result = client.articles.search_all(**Kit.snake_args(fx["sdk"]["args"]), max_pages: 2)
    pages = result.pages.to_a
    expect(pages.size).to eq(2)
    expect(mock_http.requests.size).to eq(2)
    expect(result.truncated?).to be(true)
    expect(result.next_cursor).to eq(fx["steps"][1]["response"]["body"]["pagination"]["nextCursor"])
    expect(log.string).to include("max_pages=2")
  end

  { "P-02" => "resize-and-reproject.json", "P-03" => "injected-to.json",
    "P-04" => "injected-default-languages.json", "P-05" => "changed-order.json",
    "P-06" => "reordered-list.json" }.each do |id, name|
    it "#{id} #{Kit.case_titles[id]}", kit_case: id do
      fx = Kit.load("fixtures/pagination/#{name}")
      script([fx["response"]])
      client = rest_client
      args = Kit.snake_args(fx["request"]["body"])
      if fx["response"]["status"] == 200
        page = client.articles.search(**args)
        expect(page.articles.map(&:id)).to eq(fx["response"]["body"]["articles"].map { |a| a["id"] })
      else
        expect { client.articles.search(**args) }.to raise_error(Finlight::CursorMismatchError) { |e|
          expect(e.errors[0].field).to eq("cursor")
          expect(e.api_kind).to eq("cursor_mismatch")
          expect(e.detail).to include("publishedAt:desc", "publishedAt:asc") if id == "P-05"
        }
        expect(mock_http.requests.size).to eq(1)
        expect(recording_clock.sleeps).to eq([])
      end
      expect(JSON.parse(mock_http.requests[0].body)).to eq(fx["request"]["body"])
    end
  end

  it "P-03/P-04 a search_all over a cursor mismatch stops with the error", kit_case: "P-03" do
    fx = Kit.load("fixtures/pagination/three-pages.json")
    mismatch = Kit.load("fixtures/pagination/injected-to.json")["response"]
    script([fx["steps"][0]["response"], mismatch])
    result = rest_client.articles.search_all(**Kit.snake_args(fx["sdk"]["args"]))
    seen = []
    expect { result.each { |a| seen << a.id } }.to raise_error(Finlight::CursorMismatchError)
    expect(seen.size).to eq(2)
    expect(mock_http.requests.size).to eq(2)
  end
end
