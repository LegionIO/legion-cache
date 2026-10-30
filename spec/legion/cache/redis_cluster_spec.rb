# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'
require 'redis-clustering'

RSpec.describe Legion::Cache::Redis, 'namespaces and cluster operations' do
  let(:cache) { Object.new.extend(described_class, Legion::Logging::Helper) }
  let(:connection) { instance_double(Redis) }
  let(:pool) { instance_double(ConnectionPool) }
  let(:stored) { {} }

  before do
    cache.instance_variable_set(:@cache_settings, { namespace: 'app', default_ttl: 60 })
    cache.instance_variable_set(:@client, pool)
    allow(pool).to receive(:with).and_yield(connection)
    allow(connection).to receive(:set) do |key, value, **options|
      next nil if options[:nx] && stored.key?(key)

      stored[key] = value
      'OK'
    end
    allow(connection).to receive(:get) { |key| stored[key] }
    allow(connection).to receive(:del) { |key| stored.delete(key) ? 1 : 0 }
    allow(connection).to receive(:mget) do |*keys|
      slots = keys.map { |key| RedisClient::Cluster::KeySlotConverter.convert(key) }.uniq
      raise Redis::CommandError, 'CROSSSLOT' if cache.cluster_mode? && slots.size > 1

      keys.map { |key| stored[key] }
    end
    allow(connection).to receive(:scan_each) do |match:, **, &block|
      stored.keys.select { |key| File.fnmatch(match, key) }.each(&block)
    end
  end

  it 'isolates all scalar writes, reads and deletes from another namespace' do
    stored['other:key'] = "S\x00other"
    cache.set('key', 'ours')
    expect(cache.get('key')).to eq('ours')
    expect(cache.set_nx('key', 'replacement')).to be(false)
    expect(cache.delete('key')).to be(true)
    expect(cache.get('key')).to be_nil
    expect(stored).to eq('other:key' => "S\x00other")
  end

  it 'returns original mget keys while grouping fully qualified cluster keys' do
    cache.instance_variable_set(:@cluster_mode, true)
    cache.mset({ '{one}:a' => 'first', '{two}:b' => { value: 2 } })
    expect(cache.mget('{one}:a', '{two}:b', 'missing')).to eq(
      '{one}:a' => 'first', '{two}:b' => { value: 2 }, 'missing' => nil
    )
  end

  it 'flushes only the selected namespace, including literal glob characters' do
    cache.instance_variable_set(:@cache_settings, { namespace: 'app[*]?' })
    cache.set('key', 'ours', ttl: 0)
    stored['appX:key'] = 'other'
    stored['legion_local:key'] = 'local'
    expect(cache.flush).to be(true)
    expect(stored).to eq('appX:key' => 'other', 'legion_local:key' => 'local')
  end

  it 'reports a failed cluster scan after partial deletion without global fallback' do
    cache.instance_variable_set(:@cluster_mode, true)
    cache.set('first', 'one')
    cache.set('second', 'two')
    allow(connection).to receive(:scan_each) do |**_, &block|
      block.call('app:first')
      raise Redis::ConnectionError, 'second node unavailable'
    end
    expect(cache.flush).to be_nil
    expect(cache.get('second')).to eq('two')
  end

  it 'refuses a flush without an isolation namespace' do
    cache.instance_variable_set(:@cache_settings, { namespace: nil })
    stored['unrelated'] = 'untouched'
    expect(cache.flush).to be_nil
    expect(stored).to eq('unrelated' => 'untouched')
  end
end
