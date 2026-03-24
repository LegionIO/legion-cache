# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memory'

RSpec.describe Legion::Cache::Memory do
  before { described_class.reset! }

  describe '.get / .set' do
    it 'stores and retrieves a value' do
      described_class.set('key1', 'value1')
      expect(described_class.get('key1')).to eq('value1')
    end

    it 'returns nil for missing key' do
      expect(described_class.get('missing')).to be_nil
    end

    it 'expires values after TTL' do
      described_class.set('expire-me', 'data', 0.1)
      sleep 0.15
      expect(described_class.get('expire-me')).to be_nil
    end
  end

  describe '.delete' do
    it 'removes a key' do
      described_class.set('del-key', 'val')
      described_class.delete('del-key')
      expect(described_class.get('del-key')).to be_nil
    end
  end

  describe '.fetch' do
    it 'returns existing value' do
      described_class.set('f-key', 'existing')
      result = described_class.fetch('f-key') { 'fallback' } # rubocop:disable Style/RedundantFetchBlock
      expect(result).to eq('existing')
    end

    it 'stores and returns block value on miss' do
      result = described_class.fetch('f-miss') { 'computed' } # rubocop:disable Style/RedundantFetchBlock
      expect(result).to eq('computed')
      expect(described_class.get('f-miss')).to eq('computed')
    end
  end

  describe '.flush' do
    it 'clears all entries' do
      described_class.set('a', 1)
      described_class.set('b', 2)
      described_class.flush
      expect(described_class.get('a')).to be_nil
      expect(described_class.get('b')).to be_nil
    end
  end

  describe '.connected?' do
    it 'returns true after setup' do
      described_class.setup
      expect(described_class.connected?).to be true
    end
  end

  describe '.shutdown' do
    it 'marks as disconnected' do
      described_class.setup
      described_class.shutdown
      expect(described_class.connected?).to be false
    end
  end

  describe 'thread safety' do
    it 'handles concurrent reads and writes' do
      described_class.setup
      threads = 20.times.map do |i|
        Thread.new do
          described_class.set("k#{i}", i)
          described_class.get("k#{i}")
        end
      end
      threads.each(&:join)
      expect(described_class.get('k0')).to eq(0)
    end
  end
end
