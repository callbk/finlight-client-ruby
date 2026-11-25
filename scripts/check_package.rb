#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds the gem into an empty folder and checks its contents (R-PKG-1): only lib/, README.md,
# CHANGELOG.md and LICENSE; never conformance/, local/, spec/, examples/ or scripts/.

require "fileutils"
require "rubygems/package"

root = File.expand_path("..", __dir__)
out = File.join(root, "pkg")
FileUtils.rm_rf(out)
FileUtils.mkdir_p(out)
spec = Dir.chdir(root) { Gem::Specification.load("finlight-client.gemspec") }
gem_path = Dir.chdir(root) { Gem::Package.build(spec, false, false, File.join(out, spec.file_name)) }
files = Gem::Package.new(gem_path).contents
problems = files.reject { |f| f.start_with?("lib/") || %w[README.md CHANGELOG.md LICENSE].include?(f) }
problems += files.grep(%r{\A(conformance|local|spec|examples|scripts)/})
puts "#{File.basename(gem_path)}: #{files.size} files"
files.each { |f| puts "  #{f}" }
abort "unexpected files in the gem: #{problems.uniq.join(", ")}" unless problems.empty?
%w[lib/finlight.rb lib/finlight-client.rb README.md CHANGELOG.md LICENSE].each do |must|
  abort "missing from the gem: #{must}" unless files.include?(must)
end
puts "package ok"
