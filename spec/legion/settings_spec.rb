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
