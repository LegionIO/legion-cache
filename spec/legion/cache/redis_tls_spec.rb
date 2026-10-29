# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'
require 'redis-clustering'

RSpec.describe 'Redis TLS configuration' do
  let(:cache) { Object.new.extend(Legion::Cache::Redis) }

  before do
    stub_const('Legion::Crypt::TLS', Module.new)
    cache.instance_variable_set(:@cache_settings, { tls: { enabled: true } })
    allow(Legion::Crypt::TLS).to receive(:resolve).and_return(enabled: true, verify: :peer)
  end

  it 'enables verified TLS on standalone connections' do
    client = cache.build_redis_client(server: 'secure.example:6380')
    config = client._client.config
    expect(config.ssl?).to be(true)
    expect(config.ssl_params[:verify_mode]).to eq(OpenSSL::SSL::VERIFY_PEER)
  ensure
    client&.close
  end

  it 'applies TLS and fixed hostname to cluster-discovered node configurations' do
    client = cache.build_redis_client(cluster: ['redis://node.example:6380'], fixed_hostname: 'secure.example')
    config = client._client.config.client_config_for_node('discovered.example:6381')
    expect(config[:ssl]).to be(true)
    expect(config[:ssl_params][:verify_mode]).to eq(OpenSSL::SSL::VERIFY_PEER)
    expect(config[:host]).to eq('secure.example')
  ensure
    client&.close
  end

  it 'does not inherit shared TLS configuration when Local explicitly disables it' do
    cache.instance_variable_set(:@cache_settings, { tls: { enabled: false } })
    allow(Legion::Crypt::TLS).to receive(:resolve) do |settings, port:|
      { enabled: settings[:enabled], verify: :peer }
    end
    client = cache.build_redis_client(server: 'plain.example:6379')
    expect(client._client.config.ssl?).to be(false)
  ensure
    client&.close
  end
end
