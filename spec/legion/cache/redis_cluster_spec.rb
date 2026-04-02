# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'

RSpec.describe Legion::Cache::Redis, 'cluster mode' do
  before do
    described_class.instance_variable_set(:@client, nil)
    described_class.instance_variable_set(:@connected, false)
    described_class.instance_variable_set(:@cluster_mode, nil)
  end

  after do
    described_class.instance_variable_set(:@client, nil)
    described_class.instance_variable_set(:@connected, false)
    described_class.instance_variable_set(:@cluster_mode, nil)
  end

  let(:cluster_nodes) { ['redis://node1:6379', 'redis://node2:6379', 'redis://node3:6379'] }

  describe '#build_redis_client cluster options' do
    it 'passes cluster nodes to Redis.new' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(cluster: cluster_nodes)).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: cluster_nodes)
      expect(result).to eq redis_instance
    end

    it 'passes replica: true when replica is enabled' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(cluster: cluster_nodes, replica: true)).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: cluster_nodes, replica: true)
      expect(result).to eq redis_instance
    end

    it 'passes fixed_hostname when provided' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(cluster: cluster_nodes, fixed_hostname: 'redis.internal')).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: cluster_nodes, fixed_hostname: 'redis.internal')
      expect(result).to eq redis_instance
    end

    it 'passes all cluster options together' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(cluster: cluster_nodes, replica: true, fixed_hostname: 'redis.internal')).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: cluster_nodes, replica: true, fixed_hostname: 'redis.internal')
      expect(result).to eq redis_instance
    end

    it 'omits replica when false' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(cluster: cluster_nodes)).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: cluster_nodes, replica: false)
      expect(result).to eq redis_instance
    end

    it 'omits fixed_hostname when nil' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(cluster: cluster_nodes)).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: cluster_nodes, fixed_hostname: nil)
      expect(result).to eq redis_instance
    end

    it 'falls back to single-node when cluster is empty' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(host: '127.0.0.1', port: 6379)).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: [])
      expect(result).to eq redis_instance
    end

    it 'falls back to single-node when cluster contains only nils' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(hash_including(host: '127.0.0.1', port: 6379)).and_return(redis_instance)
      result = described_class.build_redis_client(cluster: [nil, nil])
      expect(result).to eq redis_instance
    end
  end

  describe '#cluster_mode?' do
    it 'returns true after connecting with cluster nodes' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).and_return(redis_instance)
      described_class.client(cluster: cluster_nodes)
      expect(described_class.cluster_mode?).to eq true
    end

    it 'returns false after connecting without cluster' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).and_return(redis_instance)
      described_class.client(server: '127.0.0.1:6379')
      expect(described_class.cluster_mode?).to eq false
    end

    it 'returns false before any connection' do
      expect(described_class.cluster_mode?).to eq false
    end
  end

  describe '#mget' do
    let(:redis_conn) { instance_double(Redis) }
    let(:pool) { instance_double(ConnectionPool) }

    before do
      described_class.instance_variable_set(:@client, pool)
      described_class.instance_variable_set(:@connected, true)
      allow(pool).to receive(:with).and_yield(redis_conn)
    end

    context 'standalone mode' do
      before { described_class.instance_variable_set(:@cluster_mode, false) }

      it 'returns a hash of key-value pairs' do
        allow(redis_conn).to receive(:mget).with('a', 'b', 'c').and_return(%w[1 2 3])
        result = described_class.mget('a', 'b', 'c')
        expect(result).to eq({ 'a' => '1', 'b' => '2', 'c' => '3' })
      end

      it 'returns empty hash for empty keys' do
        result = described_class.mget
        expect(result).to eq({})
      end

      it 'handles nil values in results' do
        allow(redis_conn).to receive(:mget).with('a', 'b').and_return(['1', nil])
        result = described_class.mget('a', 'b')
        expect(result).to eq({ 'a' => '1', 'b' => nil })
      end

      it 'accepts keys as an array' do
        allow(redis_conn).to receive(:mget).with('x', 'y').and_return(%w[10 20])
        result = described_class.mget(%w[x y])
        expect(result).to eq({ 'x' => '10', 'y' => '20' })
      end
    end

    context 'cluster mode' do
      before { described_class.instance_variable_set(:@cluster_mode, true) }

      it 'groups keys by slot and merges results' do
        converter = class_double('Redis::Cluster::KeySlotConverter').as_stubbed_const
        allow(converter).to receive(:convert).with('a').and_return(0)
        allow(converter).to receive(:convert).with('b').and_return(1)
        allow(converter).to receive(:convert).with('c').and_return(0)

        allow(redis_conn).to receive(:mget).with('a', 'c').and_return(%w[1 3])
        allow(redis_conn).to receive(:mget).with('b').and_return(['2'])

        result = described_class.mget('a', 'b', 'c')
        expect(result).to eq({ 'a' => '1', 'b' => '2', 'c' => '3' })
      end

      it 'handles single-slot keys normally' do
        converter = class_double('Redis::Cluster::KeySlotConverter').as_stubbed_const
        allow(converter).to receive(:convert).and_return(5)

        allow(redis_conn).to receive(:mget).with('x', 'y').and_return(%w[10 20])

        result = described_class.mget('x', 'y')
        expect(result).to eq({ 'x' => '10', 'y' => '20' })
      end
    end
  end

  describe '#mset' do
    let(:redis_conn) { instance_double(Redis) }
    let(:pool) { instance_double(ConnectionPool) }

    before do
      described_class.instance_variable_set(:@client, pool)
      described_class.instance_variable_set(:@connected, true)
      allow(pool).to receive(:with).and_yield(redis_conn)
    end

    context 'standalone mode' do
      before { described_class.instance_variable_set(:@cluster_mode, false) }

      it 'sets all key-value pairs' do
        allow(redis_conn).to receive(:mset).with('a', '1', 'b', '2').and_return('OK')
        result = described_class.mset({ 'a' => '1', 'b' => '2' })
        expect(result).to eq true
      end

      it 'returns true for empty hash' do
        result = described_class.mset({})
        expect(result).to eq true
      end
    end

    context 'cluster mode' do
      before { described_class.instance_variable_set(:@cluster_mode, true) }

      it 'groups keys by slot and sets per group' do
        converter = class_double('Redis::Cluster::KeySlotConverter').as_stubbed_const
        allow(converter).to receive(:convert).with('a').and_return(0)
        allow(converter).to receive(:convert).with('b').and_return(1)

        allow(redis_conn).to receive(:mset).with('a', '1').and_return('OK')
        allow(redis_conn).to receive(:mset).with('b', '2').and_return('OK')

        result = described_class.mset({ 'a' => '1', 'b' => '2' })
        expect(result).to eq true
      end

      it 'handles same-slot keys in single call' do
        converter = class_double('Redis::Cluster::KeySlotConverter').as_stubbed_const
        allow(converter).to receive(:convert).and_return(5)

        allow(redis_conn).to receive(:mset).with('x', '10', 'y', '20').and_return('OK')

        result = described_class.mset({ 'x' => '10', 'y' => '20' })
        expect(result).to eq true
      end
    end
  end

  describe 'exception handling' do
    let(:redis_conn) { instance_double(Redis) }
    let(:pool) { instance_double(ConnectionPool) }

    before do
      described_class.instance_variable_set(:@client, pool)
      described_class.instance_variable_set(:@connected, true)
      described_class.instance_variable_set(:@cluster_mode, false)
      allow(pool).to receive(:with).and_yield(redis_conn)
    end

    it 'routes get failures through handle_exception and re-raises' do
      allow(redis_conn).to receive(:get).and_raise(Redis::BaseError, 'node down')
      allow(described_class).to receive(:handle_exception)
      expect { described_class.send(:get, 'key') }.to raise_error(Redis::BaseError)
      expect(described_class).to have_received(:handle_exception).with(
        an_instance_of(Redis::BaseError),
        level:     :warn,
        handled:   false,
        operation: 'redis_get',
        key:       'key'
      )
    end

    it 'routes set failures through handle_exception and re-raises' do
      allow(redis_conn).to receive(:set).and_raise(Redis::BaseError, 'write failed')
      allow(described_class).to receive(:handle_exception)
      expect { described_class.send(:set, 'key', 'val') }.to raise_error(Redis::BaseError)
      expect(described_class).to have_received(:handle_exception).with(
        an_instance_of(Redis::BaseError),
        level:     :warn,
        handled:   false,
        operation: 'redis_set',
        key:       'key',
        ttl:       nil
      )
    end

    it 'routes delete failures through handle_exception and re-raises' do
      allow(redis_conn).to receive(:del).and_raise(Redis::BaseError, 'conn lost')
      allow(described_class).to receive(:handle_exception)
      expect { described_class.send(:delete, 'key') }.to raise_error(Redis::BaseError)
      expect(described_class).to have_received(:handle_exception).with(
        an_instance_of(Redis::BaseError),
        level:     :warn,
        handled:   false,
        operation: 'redis_delete',
        key:       'key'
      )
    end

    it 'routes mget failures through handle_exception and re-raises' do
      allow(redis_conn).to receive(:mget).and_raise(Redis::BaseError, 'cluster fail')
      allow(described_class).to receive(:handle_exception)
      expect { described_class.mget('a') }.to raise_error(Redis::BaseError)
      expect(described_class).to have_received(:handle_exception).with(
        an_instance_of(Redis::BaseError),
        level:     :warn,
        handled:   false,
        operation: 'redis_mget',
        key_count: 1
      )
    end

    it 'routes mset failures through handle_exception and re-raises' do
      allow(redis_conn).to receive(:mset).and_raise(Redis::BaseError, 'cluster fail')
      allow(described_class).to receive(:handle_exception)
      expect { described_class.mset({ 'a' => '1' }) }.to raise_error(Redis::BaseError)
      expect(described_class).to have_received(:handle_exception).with(
        an_instance_of(Redis::BaseError),
        level:     :warn,
        handled:   false,
        operation: 'redis_mset',
        key_count: 1
      )
    end

    it 'routes flush failures through handle_exception and re-raises' do
      allow(redis_conn).to receive(:flushdb).and_raise(Redis::BaseError, 'flush fail')
      allow(described_class).to receive(:handle_exception)
      expect { described_class.flush }.to raise_error(Redis::BaseError)
      expect(described_class).to have_received(:handle_exception).with(
        an_instance_of(Redis::BaseError),
        level:     :warn,
        handled:   false,
        operation: 'redis_flush'
      )
    end
  end

  describe '#flush in cluster mode' do
    let(:redis_conn) { instance_double(Redis) }
    let(:pool) { instance_double(ConnectionPool) }

    before do
      described_class.instance_variable_set(:@client, pool)
      described_class.instance_variable_set(:@connected, true)
      described_class.instance_variable_set(:@cluster_mode, true)
      allow(pool).to receive(:with).and_yield(redis_conn)
    end

    it 'flushes all primary nodes' do
      node_info = "abc123 10.0.0.1:6379@16379 master - 0 0 1 connected 0-5460\ndef456 10.0.0.2:6379@16379 master - 0 0 2 connected 5461-10922\n"
      allow(redis_conn).to receive(:cluster).with('nodes').and_return(node_info)

      node1 = instance_double(Redis)
      node2 = instance_double(Redis)
      allow(Redis).to receive(:new).with(host: '10.0.0.1', port: 6379).and_return(node1)
      allow(Redis).to receive(:new).with(host: '10.0.0.2', port: 6379).and_return(node2)
      allow(node1).to receive(:flushdb)
      allow(node1).to receive(:close)
      allow(node2).to receive(:flushdb)
      allow(node2).to receive(:close)

      expect(described_class.flush).to eq true
    end

    it 'falls back to single flushdb on cluster nodes error' do
      allow(redis_conn).to receive(:cluster).and_raise(StandardError, 'cluster info failed')
      allow(redis_conn).to receive(:flushdb).and_return('OK')
      expect(described_class.flush).to eq true
    end
  end

  describe 'settings defaults' do
    it 'includes cluster key defaulting to nil' do
      defaults = Legion::Cache::Settings.default
      expect(defaults).to have_key(:cluster)
      expect(defaults[:cluster]).to be_nil
    end

    it 'includes replica key defaulting to false' do
      defaults = Legion::Cache::Settings.default
      expect(defaults).to have_key(:replica)
      expect(defaults[:replica]).to eq false
    end

    it 'includes fixed_hostname key defaulting to nil' do
      defaults = Legion::Cache::Settings.default
      expect(defaults).to have_key(:fixed_hostname)
      expect(defaults[:fixed_hostname]).to be_nil
    end
  end
end
