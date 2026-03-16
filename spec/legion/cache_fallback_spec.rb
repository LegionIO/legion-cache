# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'Legion::Cache fallback' do
  describe '.local' do
    it 'returns Legion::Cache::Local' do
      expect(Legion::Cache.local).to eq Legion::Cache::Local
    end
  end

  describe '.using_local?' do
    it 'responds to using_local?' do
      expect(Legion::Cache).to respond_to(:using_local?)
    end

    it 'defaults to false when shared is available' do
      Legion::Cache.setup
      expect(Legion::Cache.using_local?).to eq false
      Legion::Cache.shutdown
    end
  end

  describe 'fallback on shared failure' do
    before do
      Legion::Cache::Local.reset!
      # Force disconnected state
      Legion::Cache.close if Legion::Cache.connected?
      Legion::Cache.instance_variable_set(:@connected, false)
      Legion::Cache.instance_variable_set(:@client, nil)
      Legion::Cache.instance_variable_set(:@using_local, false)
      # Stub client to raise a connection error (no network calls)
      allow(Legion::Cache).to receive(:client).and_raise(RuntimeError, 'connection refused')
    end

    after do
      allow(Legion::Cache).to receive(:client).and_call_original
      Legion::Cache::Local.shutdown if Legion::Cache::Local.connected?
      Legion::Cache.instance_variable_set(:@using_local, false)
      Legion::Cache.instance_variable_set(:@connected, false)
    end

    it 'falls back to local when shared raises' do
      Legion::Cache.setup
      expect(Legion::Cache.connected?).to eq true
      expect(Legion::Cache.using_local?).to eq true
    end

    it 'delegates get/set/delete to local when in fallback mode' do
      Legion::Cache.setup
      expect(Legion::Cache.set('fallback_test', 'works')).to eq true
      expect(Legion::Cache.get('fallback_test')).to eq 'works'
      expect(Legion::Cache.delete('fallback_test')).to eq true
    end

    it 'delegates fetch to local when in fallback mode' do
      Legion::Cache.setup
      Legion::Cache.set('fetch_test', 'fetchval')
      expect(Legion::Cache.fetch('fetch_test')).to eq 'fetchval'
    end

    it 'delegates flush to local when in fallback mode' do
      Legion::Cache.setup
      Legion::Cache.set('flush_test', 'bye')
      expect(Legion::Cache.flush).to eq true
    end
  end

  describe 'shutdown' do
    it 'resets using_local? to false after shutdown' do
      Legion::Cache.setup
      Legion::Cache.shutdown
      expect(Legion::Cache.using_local?).to eq false
    end
  end
end
