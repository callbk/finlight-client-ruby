#!/usr/bin/env ruby
# frozen_string_literal: true

# Copies the finlight API v3 contract kit into conformance/ and checks it.
#
#   ruby scripts/sync_conformance.rb [--from PATH]   copy the kit, then verify the copy
#   ruby scripts/sync_conformance.rb --check         verify conformance/ against its MANIFEST
#
# PATH is the kit directory (shared/contracts/api-v3 in the finlight monorepo).
# Default: $FINLIGHT_CONTRACT_KIT, else ../../../../contracts/api-v3 (where the kit
# sits when this repo is the monorepo submodule). The source is checked against
# its own MANIFEST first; conformance/ is then replaced by exactly the files the
# MANIFEST lists, plus the MANIFEST itself.

require "digest"
require "fileutils"

module ConformanceKit
  ROOT = File.expand_path("..", __dir__)
  TARGET = File.join(ROOT, "conformance")

  module_function

  def read_manifest(kit)
    File.read(File.join(kit, "MANIFEST"), encoding: "UTF-8").lines.each_with_object({}) do |line, out|
      line = line.chomp
      next if line.strip.empty?

      digest, rel = line.split("  ", 2)
      raise "malformed MANIFEST line: #{line.inspect}" if rel.nil? || digest.length != 64

      out[rel] = digest
    end
  end

  # Checks every file of the kit against its MANIFEST and returns the entries.
  def verify(kit)
    entries = read_manifest(kit)
    problems = []
    entries.each do |rel, digest|
      path = File.join(kit, rel)
      if !File.file?(path)
        problems << "missing: #{rel}"
      elsif Digest::SHA256.file(path).hexdigest != digest
        problems << "checksum differs: #{rel}"
      end
    end
    listed = entries.keys + ["MANIFEST"]
    Dir.glob("**/*", File::FNM_DOTMATCH, base: kit).each do |rel|
      next unless File.file?(File.join(kit, rel))

      problems << "not in MANIFEST: #{rel}" unless listed.include?(rel)
    end
    raise "contract kit does not match its MANIFEST:\n  #{problems.join("\n  ")}" unless problems.empty?

    entries
  end

  def sync(source)
    kit = File.expand_path(source)
    raise "no contract kit at #{kit} (pass --from PATH)" unless File.file?(File.join(kit, "MANIFEST"))

    entries = verify(kit)
    FileUtils.rm_rf(TARGET)
    (entries.keys.sort + ["MANIFEST"]).each do |rel|
      dest = File.join(TARGET, rel)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(File.join(kit, rel), dest)
    end
    verify(TARGET)
    version = File.read(File.join(TARGET, "CONTRACT_VERSION")).strip
    "conformance/ synced: contract #{version}, #{entries.size} files"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.include?("--check")
      entries = ConformanceKit.verify(ConformanceKit::TARGET)
      version = File.read(File.join(ConformanceKit::TARGET, "CONTRACT_VERSION")).strip
      puts "conformance/ matches its MANIFEST: contract #{version}, #{entries.size} files"
    else
      index = ARGV.index("--from")
      default = ENV.fetch("FINLIGHT_CONTRACT_KIT",
                          File.join(ConformanceKit::ROOT, "..", "..", "..", "..", "contracts", "api-v3"))
      puts ConformanceKit.sync(index ? ARGV.fetch(index + 1) : default)
    end
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
