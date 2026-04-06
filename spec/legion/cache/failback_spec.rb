# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'failback to local' do
  let(:local_store) { {} }

  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Settings[:cache][:failback_to_local] = true

    allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
    allow(Legion::Cache::Local).to receive(:enabled?).and_return(true)
    allow(Legion::Cache::Local).to receive(:get) { |key| local_store[key] }
    allow(Legion::Cache::Local).to receive(:set) do |key, value, **|
      local_store[key] = value
      true
    end
    allow(Legion::Cache::Local).to receive(:set_sync) do |key, value, **|
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

      value = block&.call
      local_store[key] = value
      value
    end
    allow(Legion::Cache::Local).to receive(:flush) do
      local_store.clear
      true
    end
  end

  after do
    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:failback_to_local] = true
  end

  describe 'when shared is disabled' do
    before { Legion::Settings[:cache][:enabled] = false }

    it 'get delegates to Local' do
      local_store['key'] = 'value'
      expect(Legion::Cache.get('key')).to eq('value')
    end

    it 'set delegates to Local' do
      Legion::Cache.set('key', 'value', async: false)
      expect(local_store['key']).to eq('value')
    end

    it 'mget delegates to Local' do
      local_store['a'] = 1
      local_store['b'] = 2
      allow(Legion::Cache::Local).to receive(:mget).with('a', 'b').and_return({ 'a' => 1, 'b' => 2 })
      expect(Legion::Cache.mget('a', 'b')).to eq({ 'a' => 1, 'b' => 2 })
    end

    it 'fetch delegates to Local' do
      result = Legion::Cache.fetch('miss', ttl: 60) { 'computed' }
      expect(result).to eq('computed')
      expect(local_store['miss']).to eq('computed')
    end

    it 'delete delegates to Local' do
      local_store['del'] = 'gone'
      Legion::Cache.delete('del', async: false)
      expect(local_store['del']).to be_nil
    end

    it 'flush delegates to Local' do
      local_store['a'] = 1
      Legion::Cache.flush
      expect(local_store).to be_empty
    end
  end

  describe 'when shared is disconnected (failure)' do
    before do
      Legion::Settings[:cache][:enabled] = true
      Legion::Cache.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    end

    it 'get delegates to Local' do
      local_store['key'] = 'value'
      expect(Legion::Cache.get('key')).to eq('value')
    end

    it 'set delegates to Local' do
      Legion::Cache.set('key', 'value', async: false)
      expect(local_store['key']).to eq('value')
    end
  end

  describe 'when failback_to_local is false' do
    before do
      Legion::Settings[:cache][:enabled] = false
      Legion::Settings[:cache][:failback_to_local] = false
    end

    it 'get returns nil instead of delegating' do
      local_store['key'] = 'value'
      expect(Legion::Cache.get('key')).to be_nil
    end
  end

  describe 'when Local is also not connected' do
    before do
      Legion::Settings[:cache][:enabled] = false
      allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
    end

    it 'get returns nil' do
      expect(Legion::Cache.get('key')).to be_nil
    end
  end
end
