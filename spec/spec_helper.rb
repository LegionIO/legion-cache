# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/settings'
require 'simplecov'
SimpleCov.start

Legion::Logging.setup(log_file: './legion.log')

require 'legion/cache/settings'
require 'legion/cache/version'
require 'legion/cache/local'
require 'legion/cache/redis_hash'
require 'legion/cache/helper'

Legion::Settings.load

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.filter_run_excluding integration: true unless ENV['RUN_INTEGRATION_SPECS'] == '1'
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
