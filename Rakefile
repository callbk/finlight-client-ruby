# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

namespace :conformance do
  desc "Copy the API v3 contract kit into conformance/: rake \"conformance:sync[<kit dir>]\""
  task :sync, [:from] do |_task, args|
    ruby "scripts/sync_conformance.rb", *(args[:from] ? ["--from", args[:from]] : [])
  end

  desc "Check conformance/ against its MANIFEST"
  task :check do
    ruby "scripts/sync_conformance.rb", "--check"
  end
end

desc "Check the README skeleton, the version table and the translations"
task :readme do
  ruby "scripts/check_readme.rb"
end

desc "Build the gem into an empty folder and check what it contains"
task :package do
  ruby "scripts/check_package.rb"
end

desc "Syntax-check the examples"
task :examples do
  Dir["examples/*.rb"].each { |file| ruby "-c", file }
end

task default: %i[conformance:check spec rubocop readme examples]
