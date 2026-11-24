# frozen_string_literal: true

require_relative "lib/finlight/version"

Gem::Specification.new do |spec|
  spec.name = "finlight-client"
  spec.version = Finlight::VERSION
  spec.authors = ["finlight.me"]
  spec.email = ["info@finlight.me"]

  spec.summary = "Official Ruby client for the finlight.me API v3"
  spec.description =
    "Breaking release: 1.0 speaks only the finlight API v3 (pin ~> 0.1 to stay on API v2). " \
    "Financial news search, company and source lookups over REST, real-time WebSocket streams " \
    "and webhook verification for finlight.me."
  spec.homepage = "https://finlight.me"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://docs.finlight.me"
  spec.metadata["source_code_uri"] = "https://github.com/callbk/finlight-client-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/callbk/finlight-client-ruby/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/callbk/finlight-client-ruby/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Only the library and its docs: never conformance/, local/, spec/, examples/ or scripts/.
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "logger", ">= 1.5"
  spec.add_dependency "websocket-driver", ">= 0.7.7", "< 1.0"
end
