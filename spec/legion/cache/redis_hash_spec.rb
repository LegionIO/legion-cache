# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'
require 'legion/cache/redis_hash'

RSpec.describe Legion::Cache::RedisHash do
  let(:cache) { Object.new.extend(Legion::Cache::Redis) }
  let(:connection) { instance_double(Redis) }
  let(:pool) { instance_double(ConnectionPool) }
  let(:hashes) { Hash.new { |hash, key| hash[key] = {} } }
  let(:sets) { Hash.new { |hash, key| hash[key] = {} } }

  before do
    cache.instance_variable_set(:@cache_settings, { namespace: 'app' })
    allow(Legion::Cache).to receive_messages(pool: pool, connected?: true, driver_name: 'redis')
    allow(Legion::Cache).to receive(:redis_key) { |key| cache.redis_key(key) }
    allow(pool).to receive(:with).and_yield(connection)
    allow(connection).to receive(:hset) { |key, *fields| hashes[key].merge!(fields.each_slice(2).to_h).size }
    allow(connection).to receive(:hgetall) { |key| hashes[key].dup }
    allow(connection).to receive(:hdel) { |key, *fields| fields.count { |field| hashes[key].delete(field) } }
    allow(connection).to receive(:zadd) { |key, score, member| sets[key][member] = score }
    allow(connection).to receive(:zrem) { |key, member| !sets[key].delete(member).nil? }
    allow(connection).to receive(:zrangebyscore) do |key, min, max, limit: nil|
      members = sets[key].select { |_, score| score.between?(min, max) }.sort_by(&:last).map(&:first)
      limit ? members.slice(*limit) : members
    end
  end

  it 'keeps hash reads, writes and field deletion within the cache namespace' do
    hashes['key']['field'] = 'unrelated'
    expect(described_class.hset('key', { field: 'ours', retained: 'value' })).to be(true)
    expect(described_class.hgetall('key')).to eq('field' => 'ours', 'retained' => 'value')
    expect(described_class.hdel('key', 'field')).to eq(1)
    expect(described_class.hgetall('key')).to eq('retained' => 'value')
    expect(hashes['key']).to eq('field' => 'unrelated')
  end

  it 'keeps sorted set updates and limited range reads in the cache namespace' do
    sets['key']['unrelated'] = 1
    described_class.zadd('key', 1, 'first')
    described_class.zadd('key', 2, 'second')
    expect(described_class.zrangebyscore('key', 0, 3, limit: [1, 1])).to eq(['second'])
    described_class.zrem('key', 'first')
    expect(described_class.zrangebyscore('key', 0, 3)).to eq(['second'])
    expect(sets['key']).to eq('unrelated' => 1)
  end

  it 'handles redis-rb boolean expiry results and persists a zero TTL' do
    deadlines = { 'app:key' => nil, 'key' => 10 }
    allow(connection).to receive(:expire) do |key, ttl|
      next false unless deadlines.key?(key)

      deadlines[key] = ttl
      true
    end
    allow(connection).to receive(:persist) { |key| !deadlines[key].nil? && (deadlines[key] = nil).nil? }
    expect(described_class.expire('key', 60)).to be(true)
    expect(described_class.expire('missing', 60)).to be(false)
    expect(described_class.expire('key', 0)).to be(true)
    expect(deadlines).to eq('app:key' => nil, 'key' => 10)
    expect { described_class.expire('key', -1) }.to raise_error(ArgumentError)
  end

  it 'does not expose a Redis hash when another driver is selected' do
    allow(Legion::Cache).to receive(:driver_name).and_return('dalli')
    expect(described_class.hgetall('key')).to be_nil
    expect(described_class.hset('key', { field: 'value' })).to be(false)
  end

  it 'reports backend failures and returns a miss' do
    allow(connection).to receive(:hgetall).and_raise(Redis::ConnectionError, 'offline')
    expect(described_class.hgetall('key')).to be_nil
  end
end
