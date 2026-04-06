# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'Legion::Cache fallback' do
  let(:local_store) { {} }

  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, false)
    Legion::Cache.instance_variable_set(:@using_local, false)
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)

    allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
    allow(Legion::Cache::Local).to receive(:setup).and_return(true)
    allow(Legion::Cache::Local).to receive(:shutdown).and_return(false)
    allow(Legion::Cache::Local).to receive(:close).and_return(false)
    allow(Legion::Cache::Local).to receive(:get) { |key| local_store[key] }
    allow(Legion::Cache::Local).to receive(:set) do |key, value, **_opts|
      local_store[key] = value
      true
    end
    allow(Legion::Cache::Local).to receive(:set_sync) do |key, value, **_opts|
      local_store[key] = value
      true
    end
    allow(Legion::Cache::Local).to receive(:delete) do |key, **|
      !local_store.delete(key).nil?
    end
    allow(Legion::Cache::Local).to receive(:delete_sync) do |key|
      !local_store.delete(key).nil?
    end
    allow(Legion::Cache::Local).to receive(:fetch) do |key, **_opts, &block|
      next local_store[key] if local_store.key?(key)

      value = block.call
      local_store[key] = value
      value
    end
    allow(Legion::Cache::Local).to receive(:flush) do
      local_store.clear
      true
    end
  end

  describe '.local' do
    it 'returns Legion::Cache::Local' do
      expect(Legion::Cache.local).to eq Legion::Cache::Local
    end
  end

  describe '.using_local?' do
    it 'responds to using_local?' do
      expect(Legion::Cache).to respond_to(:using_local?)
    end
  end

  describe 'fallback on shared failure' do
    before do
      allow(Legion::Cache).to receive(:client).and_raise(RuntimeError, 'connection refused')
    end

    it 'falls back to local when shared raises' do
      Legion::Cache.setup
      expect(Legion::Cache.connected?).to be(true)
      expect(Legion::Cache.using_local?).to be(true)
    end

    it 'delegates get/set/delete to local when in fallback mode' do
      Legion::Cache.setup
      expect(Legion::Cache.set('fallback_test', 'works', async: false)).to be(true)
      expect(Legion::Cache.get('fallback_test')).to eq('works')
      expect(Legion::Cache.delete('fallback_test', async: false)).to be(true)
    end

    it 'delegates fetch blocks to local when in fallback mode' do
      Legion::Cache.setup
      fetch_block = proc { 'fetchval' }

      expect(Legion::Cache.fetch('fetch_test', ttl: 60, &fetch_block)).to eq('fetchval')
      expect(Legion::Cache.fetch('fetch_test')).to eq('fetchval')
    end

    it 'delegates flush to local when in fallback mode' do
      Legion::Cache.setup
      Legion::Cache.set('flush_test', 'bye', async: false)

      expect(Legion::Cache.flush).to be(true)
      expect(Legion::Cache.get('flush_test')).to be_nil
    end
  end

  describe 'shutdown' do
    it 'resets using_local? to false after shutdown' do
      allow(Legion::Cache).to receive(:client).and_raise(RuntimeError, 'connection refused')

      Legion::Cache.setup
      Legion::Cache.shutdown
      expect(Legion::Cache.using_local?).to be(false)
    end
  end
end
