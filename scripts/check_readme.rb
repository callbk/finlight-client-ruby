#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the READMEs (R-DOCS-1): README.md has exactly the shared section skeleton in order, the
# version table and the breaking-release notice; Ruby code blocks compile. The translations have the
# same heading levels and the same code blocks as README.md, and say at the top that they follow later.

ROOT = File.expand_path("..", __dir__)
SKELETON = [
  "# finlight client for Ruby",
  "## Versions",
  "## Requirements",
  "## Installation",
  "## Quick start",
  "## Search articles",
  "## Look up articles, companies and sources",
  "## Absent, null and empty",
  "## Real-time streams",
  "## Webhooks",
  "## Errors and retries",
  "## Configuration",
  "## Logging",
  "## Data notes",
  "## Migrating from 0.x",
  "## Development",
  "## License"
].freeze
TRANSLATIONS = %w[README.zh-CN.md README.ja.md README.ko.md].freeze
FENCE = /^```(\w*)\n(.*?)^```/m

def headings(text)
  text.gsub(FENCE, "").lines.map(&:strip).grep(/\A\#{1,6} /)
end

problems = []
english = File.read(File.join(ROOT, "README.md"))
problems << "README.md headings differ from the skeleton:\n  #{headings(english).join("\n  ")}" if
  headings(english) != SKELETON
problems << "README.md has no version table" unless english.include?("| SDK version | API version | Status |")
problems << "README.md must start with the breaking-release notice" unless
  english.split("## Versions").first.include?("**Breaking release.**")
blocks = english.scan(FENCE)
blocks.each do |lang, code|
  next unless lang == "ruby"

  begin
    RubyVM::InstructionSequence.compile(code)
  rescue SyntaxError => e
    problems << "README.md ruby block does not compile: #{e.message.lines.first}"
  end
end
levels = SKELETON.map { |h| h.split.first }
TRANSLATIONS.each do |name|
  text = File.read(File.join(ROOT, name))
  structure = headings(text).map { |h| h.split.first }
  problems << "#{name}: heading structure differs from README.md" if structure != levels
  problems << "#{name}: code blocks differ from README.md" if text.scan(FENCE) != blocks
  problems << "#{name}: no version table" unless text.include?("| SDK version | API version |")
end
problems.each { |p| warn p }
exit(problems.empty? ? 0 : 1)
