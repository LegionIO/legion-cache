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

    it 'defaults servers to empty array (resolved at connection time)' do
      expect(defaults[:servers]).to eq([])
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

  describe 'default TTL values' do
    it 'has global default_ttl of 3600' do
      expect(Legion::Cache::Settings.default[:default_ttl]).to eq(3600)
    end

    it 'has local default_ttl of 21600' do
      expect(Legion::Cache::Settings.local[:default_ttl]).to eq(21_600)
    end
  end

  describe 'async settings' do
    it 'includes async defaults' do
      expect(Legion::Cache::Settings.default[:async]).to include(
        pool_size: 4,
        queue_size: 1000,
        shutdown_timeout: 5
      )
    end
  end

  describe 'reconnect settings' do
    it 'includes reconnect defaults' do
      expect(Legion::Cache::Settings.default[:reconnect]).to include(
        initial_delay: 1,
        max_delay: 60,
        enabled: true
      )
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

    it 'defaults servers to empty array (resolved at connection time)' do
      expect(locals[:servers]).to eq([])
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

  describe '.resolve_servers' do
    it 'returns default localhost with memcached port when no servers given' do
      result = described_class.resolve_servers(driver: 'memcached')
      expect(result).to eq(['127.0.0.1:11211'])
    end

    it 'returns default localhost with redis port when no servers given' do
      result = described_class.resolve_servers(driver: 'redis')
      expect(result).to eq(['127.0.0.1:6379'])
    end

    it 'accepts a singular server string' do
      result = described_class.resolve_servers(driver: 'memcached', server: '10.0.0.5')
      expect(result).to eq(['10.0.0.5:11211'])
    end

    it 'accepts a servers array' do
      result = described_class.resolve_servers(driver: 'redis', servers: ['10.0.0.5', '10.0.0.6'])
      expect(result).to eq(['10.0.0.5:6379', '10.0.0.6:6379'])
    end

    it 'merges singular and plural together' do
      result = described_class.resolve_servers(
        driver: 'memcached', server: '10.0.0.5', servers: ['10.0.0.6']
      )
      expect(result).to contain_exactly('10.0.0.6:11211', '10.0.0.5:11211')
    end

    it 'preserves explicit ports' do
      result = described_class.resolve_servers(driver: 'memcached', servers: ['10.0.0.5:9999'])
      expect(result).to eq(['10.0.0.5:9999'])
    end

    it 'injects default port only where missing' do
      result = described_class.resolve_servers(
        driver: 'redis', servers: ['10.0.0.5:9999', '10.0.0.6']
      )
      expect(result).to eq(['10.0.0.5:9999', '10.0.0.6:6379'])
    end

    it 'deduplicates entries' do
      result = described_class.resolve_servers(
        driver: 'memcached', server: '10.0.0.5', servers: ['10.0.0.5']
      )
      expect(result).to eq(['10.0.0.5:11211'])
    end

    it 'allows port override' do
      result = described_class.resolve_servers(driver: 'memcached', servers: ['10.0.0.5'], port: 22_122)
      expect(result).to eq(['10.0.0.5:22122'])
    end

    it 'handles dalli as memcached' do
      result = described_class.resolve_servers(driver: 'dalli')
      expect(result).to eq(['127.0.0.1:11211'])
    end

    it 'adds the default port to raw IPv6 hosts' do
      result = described_class.resolve_servers(driver: 'redis', servers: ['::1'])
      expect(result).to eq(['[::1]:6379'])
    end

    it 'adds the default port to bracketed IPv6 hosts without one' do
      result = described_class.resolve_servers(driver: 'redis', servers: ['[::1]'])
      expect(result).to eq(['[::1]:6379'])
    end

    it 'preserves explicit ports for bracketed IPv6 hosts' do
      result = described_class.resolve_servers(driver: 'redis', servers: ['[::1]:6380'])
      expect(result).to eq(['[::1]:6380'])
    end
  end

  describe '.register_defaults!' do
    it 'merges both shared and local defaults when Legion::Settings can merge settings' do
      allow(Legion::Settings).to receive(:merge_settings)

      described_class.register_defaults!

      expect(Legion::Settings).to have_received(:merge_settings).with(:cache, hash_including(namespace: 'legion'))
      expect(Legion::Settings).to have_received(:merge_settings).with(:cache_local, hash_including(namespace: 'legion_local'))
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
