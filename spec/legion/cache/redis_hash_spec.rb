# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis_hash'

RSpec.describe Legion::Cache::RedisHash do
  subject(:mod) { Legion::Cache::RedisHash }

  describe '.redis_available?' do
    context 'when the cache pool is nil' do
      before { allow(Legion::Cache).to receive(:pool).and_return(nil) }

      it 'returns false' do
        expect(mod.redis_available?).to be false
      end
    end

    context 'when the cache is not connected' do
      before do
        pool = double('ConnectionPool')
        allow(Legion::Cache).to receive(:pool).and_return(pool)
        allow(Legion::Cache).to receive(:connected?).and_return(false)
        allow(Legion::Cache).to receive(:driver_name).and_return('redis')
      end

      it 'returns false' do
        expect(mod.redis_available?).to be false
      end
    end

    context 'when the cache is connected on Redis' do
      before do
        pool = double('ConnectionPool')
        allow(Legion::Cache).to receive(:pool).and_return(pool)
        allow(Legion::Cache).to receive(:connected?).and_return(true)
        allow(Legion::Cache).to receive(:driver_name).and_return('redis')
      end

      it 'returns true' do
        expect(mod.redis_available?).to be true
      end
    end

    context 'when the cache is connected on Memcached' do
      before do
        pool = double('ConnectionPool')
        allow(Legion::Cache).to receive(:pool).and_return(pool)
        allow(Legion::Cache).to receive(:connected?).and_return(true)
        allow(Legion::Cache).to receive(:driver_name).and_return('dalli')
      end

      it 'returns false' do
        expect(mod.redis_available?).to be false
      end
    end

    context 'when an exception is raised' do
      before { allow(Legion::Cache).to receive(:pool).and_raise(RuntimeError, 'boom') }

      it 'returns false' do
        expect(mod.redis_available?).to be false
      end
    end
  end

  describe 'does not access @client directly' do
    it 'uses Legion::Cache.pool instead of instance_variable_get' do
      source = File.read(File.expand_path('../../../lib/legion/cache/redis_hash.rb', __dir__))
      expect(source).not_to include('instance_variable_get(:@client)')
    end
  end

  describe 'safe defaults when Redis is unavailable' do
    before { allow(mod).to receive(:redis_available?).and_return(false) }

    it '#hset returns false' do
      expect(mod.hset('key', { 'a' => '1' })).to be false
    end

    it '#hgetall returns nil' do
      expect(mod.hgetall('key')).to be_nil
    end

    it '#hdel returns 0' do
      expect(mod.hdel('key', 'field')).to eq 0
    end

    it '#zadd returns false' do
      expect(mod.zadd('key', 1.0, 'member')).to be false
    end

    it '#zrangebyscore returns empty array' do
      expect(mod.zrangebyscore('key', 0, 100)).to eq []
    end

    it '#zrem returns false' do
      expect(mod.zrem('key', 'member')).to be false
    end

    it '#expire returns false' do
      expect(mod.expire('key', 3600)).to be false
    end
  end

  describe 'Redis command delegation' do
    let(:conn) { double('Redis connection') }
    let(:pool) { double('ConnectionPool') }

    before do
      allow(mod).to receive(:redis_available?).and_return(true)
      allow(Legion::Cache).to receive(:pool).and_return(pool)
      allow(pool).to receive(:with).and_yield(conn)
    end

    describe '#hset' do
      it 'calls conn.hset with flattened key-value pairs and returns true' do
        allow(conn).to receive(:hset).with('mykey', 'field1', 'val1', 'field2', 'val2').and_return(2)
        expect(mod.hset('mykey', { 'field1' => 'val1', 'field2' => 'val2' })).to be true
      end
    end

    describe '#hgetall' do
      it 'returns the hash from conn.hgetall' do
        allow(conn).to receive(:hgetall).with('mykey').and_return({ 'f' => 'v' })
        expect(mod.hgetall('mykey')).to eq({ 'f' => 'v' })
      end

      it 'returns nil when conn.hgetall returns empty hash' do
        allow(conn).to receive(:hgetall).with('mykey').and_return({})
        expect(mod.hgetall('mykey')).to eq({})
      end
    end

    describe '#hdel' do
      it 'calls conn.hdel with fields and returns the result' do
        allow(conn).to receive(:hdel).with('mykey', 'field1').and_return(1)
        expect(mod.hdel('mykey', 'field1')).to eq 1
      end
    end

    describe '#zadd' do
      it 'calls conn.zadd with stringified member and returns true' do
        allow(conn).to receive(:zadd).with('zkey', 1.5, 'member1').and_return(1)
        expect(mod.zadd('zkey', 1.5, 'member1')).to be true
      end
    end

    describe '#zrangebyscore' do
      it 'calls conn.zrangebyscore and returns the array' do
        allow(conn).to receive(:zrangebyscore).with('zkey', 0, 100).and_return(%w[a b])
        expect(mod.zrangebyscore('zkey', 0, 100)).to eq %w[a b]
      end

      it 'passes limit option when provided' do
        allow(conn).to receive(:zrangebyscore).with('zkey', 0, 100, limit: [0, 10]).and_return(['a'])
        expect(mod.zrangebyscore('zkey', 0, 100, limit: [0, 10])).to eq ['a']
      end
    end

    describe '#zrem' do
      it 'calls conn.zrem and returns true' do
        allow(conn).to receive(:zrem).with('zkey', 'member1').and_return(1)
        expect(mod.zrem('zkey', 'member1')).to be true
      end
    end

    describe '#expire' do
      it 'calls conn.expire and returns true when Redis returns 1' do
        allow(conn).to receive(:expire).with('mykey', 3600).and_return(1)
        expect(mod.expire('mykey', 3600)).to be true
      end

      it 'returns false when Redis returns 0 (key not found)' do
        allow(conn).to receive(:expire).with('missing', 60).and_return(0)
        expect(mod.expire('missing', 60)).to be false
      end
    end
  end

  describe 'error handling' do
    let(:conn) { double('Redis connection') }
    let(:pool) { double('ConnectionPool') }

    before do
      allow(mod).to receive(:redis_available?).and_return(true)
      allow(Legion::Cache).to receive(:pool).and_return(pool)
      allow(pool).to receive(:with).and_yield(conn)
    end

    it '#hset returns false on StandardError' do
      allow(conn).to receive(:hset).and_raise(StandardError, 'fail')
      expect(mod.hset('k', { 'a' => '1' })).to be false
    end

    it '#hgetall returns nil on StandardError' do
      allow(conn).to receive(:hgetall).and_raise(StandardError, 'fail')
      expect(mod.hgetall('k')).to be_nil
    end

    it '#zadd returns false on StandardError' do
      allow(conn).to receive(:zadd).and_raise(StandardError, 'fail')
      expect(mod.zadd('k', 1.0, 'm')).to be false
    end

    it '#zrangebyscore returns empty array on StandardError' do
      allow(conn).to receive(:zrangebyscore).and_raise(StandardError, 'fail')
      expect(mod.zrangebyscore('k', 0, 1)).to eq []
    end

    it '#zrem returns false on StandardError' do
      allow(conn).to receive(:zrem).and_raise(StandardError, 'fail')
      expect(mod.zrem('k', 'm')).to be false
    end

    it '#expire returns false on StandardError' do
      allow(conn).to receive(:expire).and_raise(StandardError, 'fail')
      expect(mod.expire('k', 60)).to be false
    end
  end
end
