# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'

RSpec.describe 'Redis transparent serialization' do
  let(:cache) { Legion::Cache::Redis.dup }
  let(:pool) { instance_double(ConnectionPool) }
  let(:redis) { instance_double(Redis) }

  before do
    cache.instance_variable_set(:@client, pool)
    cache.instance_variable_set(:@connected, true)
    allow(pool).to receive(:with).and_yield(redis)
  end

  describe 'set_sync serializes complex types' do
    it 'prefixes strings with S' do
      expect(redis).to receive(:set).with('k', "S\x00hello", any_args).and_return('OK')
      cache.set_sync('k', 'hello', ttl: 60)
    end

    it 'prefixes hashes with J and JSON-encodes' do
      expect(redis).to receive(:set).with('k', /\AJ\x00/, any_args).and_return('OK')
      cache.set_sync('k', { foo: 'bar' }, ttl: 60)
    end

    it 'prefixes arrays with J and JSON-encodes' do
      expect(redis).to receive(:set).with('k', /\AJ\x00/, any_args).and_return('OK')
      cache.set_sync('k', [1, 2, 3], ttl: 60)
    end
  end

  describe 'get deserializes based on prefix' do
    it 'returns plain string for S prefix' do
      allow(redis).to receive(:get).and_return("S\x00hello")
      expect(cache.get('k')).to eq('hello')
    end

    it 'returns parsed hash for J prefix' do
      json = Legion::JSON.dump({ foo: 'bar' })
      allow(redis).to receive(:get).and_return("J\x00#{json}")
      result = cache.get('k')
      expect(result).to be_a(Hash)
      expect(result[:foo] || result['foo']).to eq('bar')
    end

    it 'returns raw string for legacy data without prefix' do
      allow(redis).to receive(:get).and_return('legacy_value')
      expect(cache.get('k')).to eq('legacy_value')
    end

    it 'returns raw string when JSON parse fails' do
      allow(redis).to receive(:get).and_return("J\x00not-valid-json{{{")
      expect(cache.get('k')).to eq("J\x00not-valid-json{{{")
    end
  end
end
