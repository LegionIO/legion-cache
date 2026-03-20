# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/settings'

RSpec.describe Legion::Cache::Settings do
  describe '.default' do
    subject(:defaults) { described_class.default }

    it 'returns a hash' do
      expect(defaults).to be_a(Hash)
    end

    it 'has a driver' do
      expect(defaults[:driver]).to be_a(String)
      expect(%w[dalli redis]).to include(defaults[:driver])
    end

    it 'has servers default' do
      expect(defaults[:servers]).to eq(['127.0.0.1:11211'])
    end

    it 'has connected set to false' do
      expect(defaults[:connected]).to eq(false)
    end

    it 'has enabled set to true' do
      expect(defaults[:enabled]).to eq(true)
    end

    it 'has namespace of legion' do
      expect(defaults[:namespace]).to eq('legion')
    end

    it 'has compress set to false' do
      expect(defaults[:compress]).to eq(false)
    end

    it 'has pool_size of 10' do
      expect(defaults[:pool_size]).to eq(10)
    end

    it 'has timeout of 5' do
      expect(defaults[:timeout]).to eq(5)
    end

    it 'has expires_in of 0' do
      expect(defaults[:expires_in]).to eq(0)
    end

    it 'has cache_nils set to false' do
      expect(defaults[:cache_nils]).to eq(false)
    end

    it 'has failover set to true' do
      expect(defaults[:failover]).to eq(true)
    end

    it 'has threadsafe set to true' do
      expect(defaults[:threadsafe]).to eq(true)
    end

    it 'has serializer set to Legion::JSON' do
      expect(defaults[:serializer]).to eq(Legion::JSON)
    end
  end

  describe '.local' do
    subject(:locals) { described_class.local }

    it 'returns a Hash' do
      expect(locals).to be_a(Hash)
    end

    it 'defaults enabled to true' do
      expect(locals[:enabled]).to eq(true)
    end

    it 'defaults servers to localhost' do
      expect(locals[:servers]).to eq(['127.0.0.1:11211'])
    end

    it 'defaults namespace to legion_local' do
      expect(locals[:namespace]).to eq('legion_local')
    end

    it 'defaults pool_size to 5' do
      expect(locals[:pool_size]).to eq(5)
    end

    it 'defaults timeout to 3' do
      expect(locals[:timeout]).to eq(3)
    end

    it 'auto-detects driver independently' do
      expect(locals[:driver]).to be_a(String)
    end
  end

  describe '.normalize_driver' do
    it 'maps redis to redis' do
      expect(described_class.normalize_driver('redis')).to eq('redis')
      expect(described_class.normalize_driver(:redis)).to eq('redis')
    end

    it 'maps memcached to dalli' do
      expect(described_class.normalize_driver('memcached')).to eq('dalli')
      expect(described_class.normalize_driver(:memcached)).to eq('dalli')
    end

    it 'maps dalli to dalli for backwards compatibility' do
      expect(described_class.normalize_driver('dalli')).to eq('dalli')
      expect(described_class.normalize_driver(:dalli)).to eq('dalli')
    end

    it 'passes through unknown drivers as strings' do
      expect(described_class.normalize_driver('custom')).to eq('custom')
    end
  end

  describe '.driver' do
    it 'returns a string' do
      expect(described_class.driver).to be_a(String)
    end

    it 'defaults to dalli when available' do
      expect(described_class.driver).to eq('dalli')
    end

    it 'accepts preferred driver' do
      expect(described_class.driver('dalli')).to eq('dalli')
    end

    it 'returns redis when preferred' do
      expect(described_class.driver('redis')).to eq('redis')
    end

    it 'falls back to secondary when primary not found' do
      expect(described_class.driver('foobar')).to be_a(String)
      expect(described_class.driver('foobar')).to eq('dalli')
    end
  end
end
