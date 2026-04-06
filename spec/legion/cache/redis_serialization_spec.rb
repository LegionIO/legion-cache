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

  describe 'mget deserializes values' do
    it 'deserializes prefixed values from mget' do
      allow(redis).to receive(:mget).with('k1', 'k2').and_return(["S\x00hello".b, "J\x00{\"a\":1}".b])
      result = cache.mget('k1', 'k2')
      expect(result['k1']).to eq('hello')
      expect(result['k2']).to be_a(Hash)
    end

    it 'handles nil values in mget' do
      allow(redis).to receive(:mget).with('k1').and_return([nil])
      result = cache.mget('k1')
      expect(result['k1']).to be_nil
    end
  end

  describe 'mset_sync serializes values' do
    it 'serializes each value through set_sync' do
      allow(redis).to receive(:set).and_return('OK')
      cache.mset_sync({ 'k1' => 'hello', 'k2' => { a: 1 } }, ttl: 60)
      expect(redis).to have_received(:set).with('k1', /\AS\x00/, any_args)
      expect(redis).to have_received(:set).with('k2', /\AJ\x00/, any_args)
    end
  end
end
