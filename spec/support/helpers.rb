# frozen_string_literal: true

# A clock for REST tests: never sleeps for real, records every wait.
class RecordingClock
  attr_reader :sleeps

  def initialize
    @sleeps = []
    @offset = 0.0
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC) + @offset
  end

  def sleep(seconds)
    @sleeps << seconds
    @offset += seconds
  end
end

module SpecHelpers
  # One shared server for the whole run; it is reset before every example.
  def mock_http
    SpecHelpers.shared_http
  end

  def self.shared_http
    @shared_http ||= MockHttp.new
  end

  def recording_clock
    @recording_clock ||= RecordingClock.new
  end

  def rest_client(**options)
    options[:api_key] ||= Kit::KEY
    options[:base_url] ||= mock_http.url
    options[:clock] ||= recording_clock
    Finlight::Client.new(**options)
  end

  # Waits (real time) until the block is true.
  def wait_until(what = "condition", timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.002
    end
  end

  def finlight_threads
    Thread.list.select { |t| t.alive? && t.name.to_s.start_with?("finlight") }
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.before { SpecHelpers.shared_http.reset }
  config.after(:suite) { SpecHelpers.shared_http.close }
end
