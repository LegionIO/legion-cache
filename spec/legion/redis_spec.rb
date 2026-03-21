# frozen_string_literal: true

require 'legion/cache/redis'

RSpec.describe Legion::Cache::Redis do
  before(:all) do
    @cache = Legion::Cache::Redis
  end

  it 'can connect' do
    expect(@cache).not_to respond_to :connect
    expect { @cache.client }.not_to raise_exception
    expect(@cache.connected?).to eq true
  end

  it 'can close' do
    expect(@cache).to respond_to :close
    expect { @cache.close }.not_to raise_error
  end

  it 'can restart' do
    expect(@cache).to respond_to :restart
    expect { @cache.restart }.not_to raise_error
  end

  it 'can set' do
    expect(@cache).to respond_to :set
    expect(@cache.set('test', 'test')).to eq true
  end

  it 'can get' do
    expect(@cache).to respond_to :get
    expect(@cache.get('test')).to eq 'test'
  end

  it 'can fetch' do
    expect(@cache.respond_to?(:fetch)).to eq true
    expect(@cache.fetch('test')).to eq 'test'
  end

  it 'can delete' do
    expect(@cache).to respond_to :delete
    expect(@cache.delete('test')).to eq true
  end

  it 'can flush' do
    expect(@cache).to respond_to :flush
    expect(@cache.flush).to eq true
  end

  it 'accepts servers parameter' do
    @cache.close if @cache.connected?
    @cache.instance_variable_set(:@client, nil)
    @cache.instance_variable_set(:@connected, false)
    expect { @cache.client(servers: ['127.0.0.1:6379']) }.not_to raise_error
    expect(@cache.connected?).to eq true
  end

  it 'wont use bogus methods' do
    expect(@cache).not_to respond_to :this_is_fake
  end

  describe '#build_redis_client' do
    before do
      @cache.instance_variable_set(:@client, nil)
      @cache.instance_variable_set(:@connected, false)
    end

    after do
      @cache.instance_variable_set(:@client, nil)
      @cache.instance_variable_set(:@connected, false)
    end

    it 'returns a single-node Redis client when no cluster is given' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(host: '127.0.0.1', port: 6379).and_return(redis_instance)
      result = @cache.build_redis_client
      expect(result).to eq redis_instance
    end

    it 'returns a cluster Redis client when cluster nodes are provided' do
      nodes = ['redis://node1:6379', 'redis://node2:6379', 'redis://node3:6379']
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(cluster: nodes).and_return(redis_instance)
      result = @cache.build_redis_client(cluster: nodes)
      expect(result).to eq redis_instance
    end

    it 'falls back to single-node when cluster is an empty array' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(host: '127.0.0.1', port: 6379).and_return(redis_instance)
      result = @cache.build_redis_client(cluster: [])
      expect(result).to eq redis_instance
    end

    it 'falls back to single-node when cluster is nil' do
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(host: '127.0.0.1', port: 6379).and_return(redis_instance)
      result = @cache.build_redis_client(cluster: nil)
      expect(result).to eq redis_instance
    end

    it 'passes cluster nodes verbatim to Redis.new' do
      nodes = ['redis://10.0.0.1:6379', 'redis://10.0.0.2:6380']
      expect(Redis).to receive(:new).with(cluster: nodes).and_return(instance_double(Redis))
      @cache.build_redis_client(cluster: nodes)
    end
  end

  describe '#client with cluster:' do
    before do
      @cache.instance_variable_set(:@client, nil)
      @cache.instance_variable_set(:@connected, false)
    end

    after do
      @cache.instance_variable_set(:@client, nil)
      @cache.instance_variable_set(:@connected, false)
    end

    it 'creates a ConnectionPool using cluster nodes when cluster: is passed' do
      nodes = ['redis://node1:6379', 'redis://node2:6379']
      redis_instance = instance_double(Redis)
      allow(Redis).to receive(:new).with(cluster: nodes).and_return(redis_instance)
      expect { @cache.client(cluster: nodes) }.not_to raise_error
      expect(@cache.connected?).to eq true
    end
  end
end
