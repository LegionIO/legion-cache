# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe Legion::Cache do
  before do
    ENV.delete('LEGION_MODE')
    Legion::Settings[:cache][:driver] = 'dalli'
    Legion::Settings[:cache][:servers] = ['127.0.0.1:11211']
    described_class.instance_variable_set(:@client, nil)
    described_class.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    described_class.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(false))
    described_class.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(false))
    described_class.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache::Local.reset!
    Legion::Cache::Memory.reset!
  end

  after do
    ENV.delete('LEGION_MODE')
    Legion::Settings[:cache][:driver] = 'dalli'
    Legion::Settings[:cache][:servers] = ['127.0.0.1:11211']
    described_class.instance_variable_set(:@client, nil)
    described_class.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    described_class.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(false))
    described_class.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(false))
    described_class.instance_variable_set(:@active_shared_driver, nil)
  end

  it 'has a version number' do
    expect(Legion::Cache::VERSION).not_to be_nil
  end

  describe '.setup' do
    it 'selects the shared adapter from settings at setup time' do
      Legion::Settings[:cache][:driver] = 'redis'
      Legion::Settings[:cache][:servers] = ['127.0.0.1:6379']
      allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
      allow(Legion::Cache::Local).to receive(:setup)

      expect { described_class.setup }.not_to raise_error
      expect(described_class.driver_name).to eq('redis')
      expect(described_class.connected?).to be(true)
    end
  end

  describe '.fetch' do
    it 'forwards blocks to the memory adapter' do
      described_class.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(true))
      described_class.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(true))
      fetch_block = proc { 'computed' }

      expect(Legion::Cache::Memory).to receive(:fetch) do |key, ttl: nil, &block|
        expect(key).to eq('cache.key')
        expect(ttl).to eq(60)
        block.call
      end.and_return('computed')

      expect(described_class.fetch('cache.key', ttl: 60, &fetch_block)).to eq('computed')
    end

    it 'forwards blocks to the local adapter' do
      described_class.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(true))
      described_class.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(true))
      fetch_block = proc { 'local-computed' }

      expect(Legion::Cache::Local).to receive(:fetch) do |key, ttl: nil, &block|
        expect(key).to eq('cache.key')
        expect(ttl).to eq(90)
        block.call
      end.and_return('local-computed')

      expect(described_class.fetch('cache.key', ttl: 90, &fetch_block)).to eq('local-computed')
    end
  end
end
