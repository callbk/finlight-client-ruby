# frozen_string_literal: true

require "finlight"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :defined
  # Live tests run only on request (FINLIGHT_LIVE=1), never in the normal test command.
  config.filter_run_excluding :live unless ENV["FINLIGHT_LIVE"] == "1"
end
