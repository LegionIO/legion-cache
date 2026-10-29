# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'
require 'redis-clustering'

RSpec.describe Legion::Cache::Redis do
  let(:cache) { Object.new.extend(described_class, Legion::Logging::Helper) }
  let(:created) { [] }
  let(:settings) do
    { servers: ['configured.example:6381'], username: 'user', password: 'secret', db: 4,
      namespace: 'configured', pool_size: 1, timeout: 0.5, default_ttl: 60 }
  end

  before do
    allow(Legion::Settings).to receive(:[]).and_call_original
    allow(Legion::Settings).to receive(:[]).with(:cache).and_return(settings)
    allow(cache).to receive(:build_redis_client).and_wrap_original do |original, **options|
      instance = original.call(**options)
      created << instance
      allow(instance).to receive(:ping).and_return('PONG')
      instance
    end
  end

  after { cache.close }

  it 'honors configured endpoint, authentication and database on first lazy access' do
    cache.client
    config = created.last._client.config
    expect([config.host, config.port, config.username, config.password, config.db]).to eq(
      ['configured.example', 6381, 'user', 'secret', 4]
    )
    expect(cache.connected?).to be(true)
  end

  it 'lets an explicit single endpoint and nil authentication override shared configuration' do
    settings[:cluster] = ['redis://shared.example:6379']
    cache.client(server: '[::1]:6382', username: nil, password: nil, db: 0)
    config = created.last._client.config
    expect([config.host, config.port, config.password, config.db]).to eq(['::1', 6382, nil, 0])
  end

  it 'uses a complete Local configuration without inheriting shared cluster or TLS options' do
    settings.merge!(cluster: ['redis://shared.example:6379'], tls: { enabled: true })
    cache.instance_variable_set(:@cache_settings, {
                                  server: 'local.example:6379', namespace: 'local', pool_size: 1, timeout: 1
                                })
    cache.client
    expect(created.last._client.config.host).to eq('local.example')
    expect(cache.cluster_mode?).to be(false)
    expect(cache.redis_key('key')).to eq('local:key')
  end

  it 'preserves Redis URL credentials and database' do
    cache.client(server: 'redis://urluser:urlpass@url.example:6383/7', username: nil, password: nil, db: nil)
    config = created.last._client.config
    expect([config.host, config.port, config.username, config.password, config.db]).to eq(
      ['url.example', 6383, 'urluser', 'urlpass', 7]
    )
  end

  it 'discards a failed health check and allows a fresh connection attempt' do
    allow(cache).to receive(:build_redis_client).and_wrap_original do |original, **options|
      instance = original.call(**options)
      created << instance
      if created.one?
        allow(instance).to receive(:ping).and_raise(Redis::CannotConnectError, 'offline')
      else
        allow(instance).to receive(:ping).and_return('PONG')
      end
      instance
    end
    expect { cache.client }.to raise_error(Redis::CannotConnectError)
    expect(cache.connected?).to be(false)
    cache.client
    expect(cache.connected?).to be(true)
    expect(created.size).to eq(2)
  end

  it 'constructs an actual supported cluster client and rejects nonzero databases' do
    cluster = cache.build_redis_client(cluster: ['redis://node.example:6379'])
    expect(cluster).to be_a(Redis::Cluster)
    expect(cluster._client.config.startup_nodes.keys).to eq(['node.example:6379'])
    expect { cache.build_redis_client(cluster: ['redis://node.example:6379'], db: 2) }.to raise_error(ArgumentError)
  ensure
    cluster&.close
  end
end
