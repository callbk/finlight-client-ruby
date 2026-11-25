# frozen_string_literal: true

require_relative "../../scripts/sync_conformance"

# Guard for R-TEST-1: every case of conformance.md must have a test, and CONFORMANCE.md must map it.
RSpec.describe "Conformance case map" do
  conformance_files = Dir[File.join(__dir__, "*_spec.rb")].map { |f| File.expand_path(f) }.sort

  # The case ids mapped in CONFORMANCE.md: { id => spec file (relative) }.
  def mapped_cases
    File.read(File.join(Kit::ROOT, "CONFORMANCE.md"))
        .scan(/^\| ([A-Z]-\d+) \| [^|]+ \| `([^`]+)` \|/).to_h
  end

  # Every example of the run, with its file: [[kit_case, file_path], ...]. All spec files are loaded
  # before any example runs, so this sees the whole suite.
  def kit_examples
    groups = RSpec.world.example_groups.flat_map { |g| [g, *g.descendants] }.uniq
    groups.flat_map(&:examples).filter_map do |example|
      id = example.metadata[:kit_case]
      [id, File.expand_path(example.metadata[:file_path], Kit::ROOT)] if id
    end
  end

  before do
    loaded = RSpec.configuration.files_to_run.map { |f| File.expand_path(f) }
    missing = conformance_files - loaded
    names = missing.map { |f| File.basename(f) }.join(", ")
    skip "the case map needs the whole conformance suite (not loaded: #{names})" unless missing.empty?
  end

  it "every kit case has at least one example with kit_case metadata" do
    ids = Kit.case_ids
    expect(ids).not_to be_empty
    covered = kit_examples.map(&:first).uniq
    expect(ids - covered).to eq([])
  end

  it "every kit case is listed in CONFORMANCE.md and its mapped file has an example for it" do
    map = mapped_cases
    expect(Kit.case_ids - map.keys).to eq([])
    by_file = kit_examples.group_by(&:last).transform_values { |list| list.map(&:first) }
    wrong = map.select do |id, file|
      by_file.fetch(File.expand_path(file, Kit::ROOT), []).none?(id)
    end
    expect(wrong).to eq({})
  end

  it "CONFORMANCE.md lists no case the kit does not have" do
    expect(mapped_cases.keys - Kit.case_ids).to eq([])
  end

  it "conformance/ matches its MANIFEST" do
    expect { ConformanceKit.verify(ConformanceKit::TARGET) }.not_to raise_error
  end
end
