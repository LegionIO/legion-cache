# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'
require 'legion/cache/memcached'
require 'legion/cache/memory'

RSpec.describe 'Legion::Cache set_nx' do
  describe Legion::Cache::Memory do
    before { described_class.reset! }

    describe '.set_nx' do
      it 'returns true and stores value when key does not exist' do
        result = described_class.set_nx('nx-key', 'value', ttl: 60)
        expect(result).to be true
        expect(described_class.get('nx-key')).to eq('value')
      end

      it 'returns false and does not overwrite when key already exists' do
        described_class.set('nx-key', 'original', ttl: 60)
        result = described_class.set_nx('nx-key', 'overwrite', ttl: 60)
        expect(result).to be false
        expect(described_class.get('nx-key')).to eq('original')
      end

      it 'returns true after an expired key has been purged' do
        described_class.set('nx-expire', 'old', ttl: 0.05)
        sleep 0.07
        result = described_class.set_nx('nx-expire', 'new', ttl: 60)
        expect(result).to be true
        expect(described_class.get('nx-expire')).to eq('new')
      end

      it 'is atomic under concurrent access' do
        winners = []
        mutex = Mutex.new
        threads = 10.times.map do |i|
          Thread.new do
            won = described_class.set_nx('race-key', "value-#{i}", ttl: 60)
            mutex.synchronize { winners << i } if won
          end
        end
        threads.each(&:join)
        expect(winners.size).to eq(1)
      end
    end
  end

  describe Legion::Cache::Redis do
    let(:cache) { described_class.dup }
    let(:pool)  { instance_double(ConnectionPool) }
    let(:redis) { instance_double(Redis) }

    before do
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)
      allow(pool).to receive(:with).and_yield(redis)
    end

    describe '#set_nx' do
      it 'returns true when Redis SET NX succeeds (returns "OK")' do
        allow(redis).to receive(:set).with('nx-key', anything, nx: true, ex: 60).and_return('OK')
        expect(cache.set_nx('nx-key', 'value', ttl: 60)).to be true
      end

      it 'returns false when Redis SET NX fails (key exists, returns nil)' do
        allow(redis).to receive(:set).with('nx-key', anything, nx: true, ex: 60).and_return(nil)
        expect(cache.set_nx('nx-key', 'value', ttl: 60)).to be false
      end

      it 'passes nx: true and ex: ttl to Redis SET' do
        expect(redis).to receive(:set).with('nx-key', anything, nx: true, ex: 120).and_return('OK')
        cache.set_nx('nx-key', 'value', ttl: 120)
      end

      it 'serializes the value before storing' do
        captured = nil
        allow(redis).to receive(:set) do |_key, val, **_opts|
          captured = val
          'OK'
        end
        cache.set_nx('nx-key', { data: 42 }, ttl: 60)
        expect(captured).to be_a(String)
      end
    end
  end

  describe Legion::Cache::Memcached do
    let(:cache) { described_class.dup }
    let(:pool)  { instance_double(ConnectionPool) }
    let(:dalli) { instance_double(Dalli::Client) }

    before do
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)
      allow(pool).to receive(:with).and_yield(dalli)
    end

    describe '#set_nx' do
      it 'returns true when Dalli#add succeeds (key did not exist)' do
        allow(dalli).to receive(:add).with('nx-key', 'value', 60).and_return(true)
        expect(cache.set_nx('nx-key', 'value', ttl: 60)).to be true
      end

      it 'returns false when Dalli#add fails (key already exists, returns nil/false)' do
        allow(dalli).to receive(:add).with('nx-key', 'value', 60).and_return(nil)
        expect(cache.set_nx('nx-key', 'value', ttl: 60)).to be false
      end

      it 'passes the ttl positionally to Dalli#add' do
        expect(dalli).to receive(:add).with('nx-key', 'value', 90).and_return(true)
        cache.set_nx('nx-key', 'value', ttl: 90)
      end
    end
  end
end
