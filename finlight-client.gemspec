# frozen_string_literal: true

require_relative "lib/finlight/client/version"

Gem::Specification.new do |spec|
  spec.name = "finlight-client"
  spec.version = Finlight::Client::VERSION
  spec.authors = ["finlight.me"]
  spec.email = ["info@finlight.me"]

  spec.summary = "Official Ruby client for the finlight.me API"
  spec.description =
    "Financial news with sentiment analysis, entity recognition and real-time streaming: " \
    "REST, WebSocket and webhook verification client for finlight.me."
  spec.homepage = "https://finlight.me"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://docs.finlight.me"
  spec.metadata["source_code_uri"] = "https://github.com/callbk/finlight-client-ruby"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "logger", "~> 1.6"
  spec.add_dependency "websocket-driver", "~> 0.8"
end
