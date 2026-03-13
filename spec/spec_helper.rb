# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/settings'
require 'simplecov'
SimpleCov.start

Legion::Logging.setup(log_file: './legion.log')
Legion::Settings.merge_settings('cache', Legion::Cache::Settings.default)
Legion::Settings.load
require 'legion/cache/settings'

require 'legion/cache/version'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
