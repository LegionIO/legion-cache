# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'

RSpec.describe 'Redis cached Ruby values' do
  let(:cache) { Object.new.extend(Legion::Cache::Redis, Legion::Logging::Helper) }
  let(:pool) { instance_double(ConnectionPool) }
  let(:redis) { instance_double(Redis) }
  let(:values) { {} }
  let(:expirations) { {} }

  before do
    cache.instance_variable_set(:@cache_settings, { namespace: 'app', default_ttl: 60 })
    cache.instance_variable_set(:@client, pool)
    allow(pool).to receive(:with).and_yield(redis)
    allow(redis).to receive(:set) do |key, value, **options|
      raise Redis::CommandError, 'invalid expire time' if options[:ex] && options[:ex] <= 0
      next nil if options[:nx] && values.key?(key)

      values[key] = value
      expirations[key] = options[:ex]
      'OK'
    end
    allow(redis).to receive(:get) { |key| values[key] }
    allow(redis).to receive(:mget) { |*keys| keys.map { |key| values[key] } }
  end

  it 'round-trips strings, hashes, arrays and false through individual and batch operations' do
    data = { 'string' => 'hello', 'hash' => { value: 1 }, 'array' => [1, 2], 'false' => false }
    cache.mset(data)
    expect(cache.mget(data.keys)).to eq(data)
    expect(cache.get('false')).to be(false)
  end

  it 'continues to read legacy unprefixed strings' do
    values['app:key'] = 'legacy'
    expect(cache.get('key')).to eq('legacy')
  end

  it 'does not reinterpret malformed cached JSON as a missing entry' do
    values['app:key'] = "J\x00not-json"
    expect(cache.get('key')).to eq("J\x00not-json")
  end

  it 'writes zero TTL values without expiry and rejects negative TTL' do
    cache.set('regular', 'value', ttl: 0)
    expect(cache.set_nx('conditional', 'value', ttl: 0)).to be(true)
    expect(cache.mget('regular', 'conditional')).to eq('regular' => 'value', 'conditional' => 'value')
    expect(expirations.values).to eq([nil, nil])
    expect { cache.set('regular', 'wrong', ttl: -1) }.to raise_error(ArgumentError)
    expect { cache.set_nx('new', 'wrong', ttl: -1) }.to raise_error(ArgumentError)
    expect(cache.get('regular')).to eq('value')
  end

  it 'returns a computed fetch result even when the backend rejects its write' do
    allow(redis).to receive(:set).and_raise(Redis::ConnectionError, 'offline')
    expect(cache.fetch('missing') { { computed: true } }).to eq(computed: true)
  end

  it 'propagates the original fetch block exception' do
    error = Redis::ConnectionError.new('application failure')
    expect { cache.fetch('missing') { raise error } }.to(raise_error { |raised| expect(raised).to equal(error) })
  end

  describe 'atomic read/modify/write' do
    let(:watched) { instance_double(Redis) }
    let(:transaction) { instance_double(Redis) }
    let(:staged) { {} }

    before do
      allow(redis).to receive(:watch).and_yield(watched)
      allow(watched).to receive(:get) { |key| values[key] }
      allow(transaction).to receive(:set) { |key, value, **options| staged.replace(key: key, value: value, options: options) }
      allow(watched).to receive(:multi) do |&block|
        block.call(transaction)
        redis.set(staged[:key], staged[:value], **staged[:options])
        ['OK']
      end
    end

    it 'creates absent entries and returns committed Ruby values' do
      expect(cache.cas('key', ttl: 0) { |current| (current || {}).merge(first: 1) }).to eq(first: 1)
      expect(cache.get('key')).to eq(first: 1)
      expect(expirations['app:key']).to be_nil
    end

    it 'retries a conflicting transaction against the latest cached value' do
      cache.set('key', { initial: 1 })
      attempts = 0
      allow(watched).to receive(:multi) do |&block|
        block.call(transaction)
        attempts += 1
        if attempts == 1
          cache.set('key', { initial: 1, concurrent: 2 })
          nil
        else
          redis.set(staged[:key], staged[:value], **staged[:options])
          ['OK']
        end
      end
      result = cache.cas('key') { |current| current.merge(ours: 3) }
      expect(result).to eq(initial: 1, concurrent: 2, ours: 3)
      expect(cache.get('key')).to eq(result)
    end

    it 'surfaces contention exhaustion without committing a speculative value' do
      cache.set('key', 'original')
      allow(watched).to receive(:multi).and_return(nil)
      expect { cache.cas('key') { 'replacement' } }.to raise_error(Redis::CommandError)
      expect(cache.get('key')).to eq('original')
    end

    it 'does not commit when the user block raises' do
      cache.set('key', 'original')
      error = Redis::ConnectionError.new('user error')
      expect { cache.cas('key') { raise error } }.to(raise_error { |raised| expect(raised).to equal(error) })
      expect(cache.get('key')).to eq('original')
    end
  end
end
