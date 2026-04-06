# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'stats' do
  describe 'Legion::Cache.stats' do
    before do
      ENV['LEGION_MODE'] = 'lite'
      Legion::Cache.setup
    end

    after do
      Legion::Cache.shutdown
      ENV.delete('LEGION_MODE')
    end

    it 'returns a hash with required keys' do
      stats = Legion::Cache.stats
      expect(stats).to be_a(Hash)
      expect(stats).to include(
        :driver, :servers, :enabled, :connected,
        :using_local, :using_memory,
        :pool_size, :pool_available,
        :async_pool_size, :async_queue_depth, :async_processed,
        :reconnect_attempts, :uptime
      )
    end

    it 'returns a frozen hash' do
      expect(Legion::Cache.stats).to be_frozen
    end

    it 'reports correct driver' do
      expect(Legion::Cache.stats[:driver]).to eq('memory')
    end
  end

  describe 'Legion::Cache::Local.stats' do
    before { Legion::Cache::Local.reset! }

    it 'responds to stats' do
      expect(Legion::Cache::Local).to respond_to(:stats)
    end

    it 'returns a hash with required keys' do
      stats = Legion::Cache::Local.stats
      expect(stats).to include(:driver, :servers, :enabled, :connected)
    end
  end
end
