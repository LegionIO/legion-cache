# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'cache backend transitions' do
  let(:backend) { { available: true, values: {}, connections: [], error: nil } }
  let(:adapter) do
    state = backend
    Module.new do
      include Legion::Cache::Pool

      define_method(:client) do |**options|
        raise IOError, 'backend unavailable' unless state[:available]

        state[:connections] << options
        @client = Object.new
        @client.define_singleton_method(:shutdown) { |&_| nil }
        cache_mark_connected(true)
        @client
      end
      define_method(:get) do |key|
        raise state[:error] if state[:error]
        raise IOError, 'backend unavailable' unless state[:available]

        state[:values][key]
      end
      define_method(:set_sync) do |key, value, **|
        raise IOError, 'backend unavailable' unless state[:available]

        state[:values][key] = value
        true
      end
      define_method(:mget) do |*keys|
        raise state[:error] if state[:error]
        raise IOError, 'backend unavailable' unless state[:available]

        keys.flatten.to_h { |key| [key, state[:values][key]] }
      end
      define_method(:delete_sync) do |key|
        raise IOError, 'backend unavailable' unless state[:available]

        !state[:values].delete(key).nil?
      end
    end
  end

  before do
    @mode = ENV.delete('LEGION_MODE')
    @settings = Legion::Settings[:cache].dup
    @local_settings = Legion::Settings[:cache_local].dup
    Legion::Cache.shutdown
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache.instance_variable_set(:@connection_options, nil)
    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:failback_to_local] = true
    Legion::Settings[:cache][:reconnect] = { enabled: false }
    Legion::Settings[:cache_local][:enabled] = true
    Legion::Cache::Memory.reset!
    allow(Legion::Cache::Local).to receive(:build_driver).and_return(Legion::Cache::Memory)
    allow(Legion::Cache).to receive(:build_shared_adapter).and_return(adapter)
  end

  after do
    Legion::Cache.shutdown
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache.instance_variable_set(:@shared_adapter, nil)
    Legion::Cache.instance_variable_set(:@connection_options, nil)
    Legion::Cache::Memory.reset!
    Legion::Settings[:cache].replace(@settings)
    Legion::Settings[:cache_local].replace(@local_settings)
    ENV['LEGION_MODE'] = @mode if @mode
  end

  it 'retries the actual failed operation on healthy Local, without re-enabling shared access' do
    Legion::Cache.setup
    backend[:available] = false

    expect(Legion::Cache.set_sync('key', 'fallback')).to be(true)
    expect(Legion::Cache.using_local?).to be(true)
    expect(Legion::Cache.get('key')).to eq('fallback')
    expect(backend[:values]).to be_empty
    expect(Legion::Cache.client).to eq(Legion::Cache::Local.client)
    expect(Legion::Cache.using_local?).to be(true)
    expect(Legion::Cache.delete_sync('key')).to be(true)
    expect(Legion::Cache.get('key')).to be_nil
  end

  it 'honors a driver notification for a handled read failure' do
    adapter.define_method(:get) do |_key|
      cache_backend_failed(IOError.new('lost connection'))
      nil
    end
    Legion::Cache.setup
    Legion::Cache::Local.set_sync('key', 'local value')

    expect(Legion::Cache.get('key')).to eq('local value')
    expect(Legion::Cache.connected?).to be(true)
  end

  it 'reads a shared miss from Local without changing the active shared tier' do
    Legion::Cache.setup
    Legion::Cache::Local.set_sync('local', 'local value')
    Legion::Cache::Local.set_sync('false', false)

    expect(Legion::Cache.get('local')).to eq('local value')
    expect(Legion::Cache.get('false')).to be(false)
    expect(Legion::Cache.using_local?).to be(false)
  end

  it 'fills only missing shared batch values from Local' do
    backend[:values]['shared'] = 'shared value'
    Legion::Cache.setup
    Legion::Cache::Local.set_sync('local', 'local value')
    Legion::Cache::Local.set_sync('false', false)

    expect(Legion::Cache.mget('shared', 'local', 'false', 'missing')).to eq(
      'shared' => 'shared value', 'local' => 'local value', 'false' => false, 'missing' => nil
    )
    expect(Legion::Cache.using_local?).to be(false)
  end

  it 'uses healthy Local without connecting shared when shared cache is disabled' do
    Legion::Settings[:cache][:enabled] = false

    expect(Legion::Cache.setup).to be(true)
    expect(Legion::Cache.set_sync('key', 'local value')).to be(true)
    expect(Legion::Cache.get('key')).to eq('local value')
    expect(Legion::Cache.client).to eq(Legion::Cache::Local.client)
    expect(Legion::Cache.using_local?).to be(true)
    expect(backend[:connections]).to be_empty
  end

  it 'fails closed for every write when both tiers are unavailable' do
    backend[:available] = false
    Legion::Settings[:cache_local][:enabled] = false
    Legion::Cache.setup

    expect(Legion::Cache.get('key')).to be_nil
    expect(Legion::Cache.set_sync('key', 'value')).to be(false)
    expect(Legion::Cache.set('key', 'value')).to be(false)
    expect(Legion::Cache.set_nx('key', 'value')).to be(false)
    expect(Legion::Cache.mset({ 'key' => 'value' })).to be(false)
    expect(Legion::Cache.delete_sync('key')).to be(false)
    expect(Legion::Cache.cas('key') { raise 'must not run' }).to be(false)
    expect(Legion::Cache.connected?).to be(false)
  end

  it 'does not use Local when fallback policy is disabled' do
    Legion::Settings[:cache][:failback_to_local] = false
    Legion::Cache.setup
    backend[:available] = false

    expect(Legion::Cache.set_sync('key', 'value')).to be(false)
    expect(Legion::Cache::Local.get('key')).to be_nil
    expect(Legion::Cache.using_local?).to be(false)
  end

  it 'does not mistake a programming error for a backend outage' do
    Legion::Cache.setup
    backend[:error] = ArgumentError.new('invalid key')

    expect { Legion::Cache.get('key') }.to raise_error(ArgumentError, 'invalid key')
    expect(Legion::Cache.using_local?).to be(false)
    expect(Legion::Cache.connected?).to be(true)
  end

  it 'returns the computed fetch result even if caching loses both tiers' do
    Legion::Cache.setup
    value = Legion::Cache.fetch('key') do
      backend[:available] = false
      Legion::Cache::Local.shutdown
      'computed'
    end

    expect(value).to eq('computed')
    expect(Legion::Cache.connected?).to be(false)
  end

  it 'retains the atomic connection object across failures and successful reconnect' do
    connected = Legion::Cache.instance_variable_get(:@connected)
    Legion::Cache.setup
    backend[:available] = false
    Legion::Cache.get('key')
    Legion::Settings[:cache][:reconnect] = { enabled: true }
    backend[:available] = true
    Legion::Cache.send(:reconnect_shared!)

    expect(Legion::Cache.instance_variable_get(:@connected)).to equal(connected)
    expect(Legion::Cache.using_local?).to be(false)
    expect(Legion::Cache.set_sync('key', 'shared')).to be(true)
    expect(backend[:values]['key']).to eq('shared')
  end

  it 'keeps Local usable when reconnect health validation fails' do
    backend[:available] = false
    Legion::Cache.setup
    Legion::Cache.set_sync('key', 'local')
    Legion::Settings[:cache][:reconnect] = { enabled: true }

    expect { Legion::Cache.send(:reconnect_shared!) }.to raise_error(IOError)
    expect(Legion::Cache.get('key')).to eq('local')
    expect(Legion::Cache.using_local?).to be(true)
  end

  it 'does not retry when reconnect is disabled' do
    backend[:available] = false
    Legion::Cache.setup
    backend[:available] = true

    expect(Legion::Cache.send(:reconnect_shared!)).to be(false)
    expect(backend[:connections]).to be_empty
    expect(Legion::Cache.instance_variable_get(:@reconnector)).to be_nil
  end

  it 'uses the configured destination for lazy setup and restart' do
    Legion::Settings[:cache].merge!(servers: ['configured:6379'], username: 'user', password: 'secret', db: 7)
    Legion::Cache.get('key')
    Legion::Cache.restart

    expect(backend[:connections].map { |config| config.slice(:servers, :username, :password, :db) }).to eq(
      Array.new(2) { { servers: ['configured:6379'], username: 'user', password: 'secret', db: 7 } }
    )
  end

  it 'replaces inherited endpoints and cluster configuration across explicit restarts' do
    Legion::Settings[:cache].merge!(servers: ['inherited:6379'], cluster: ['inherited-cluster:6379'])
    Legion::Cache.setup(server: 'override:6380', username: nil, password: nil, db: 2)
    Legion::Cache.restart(servers: ['replacement:6381'])

    first, second = backend[:connections]
    expect(first.slice(:server, :servers, :cluster, :username, :password, :db)).to eq(
      server: 'override:6380', servers: [], cluster: nil, username: nil, password: nil, db: 2
    )
    expect(second.slice(:server, :servers, :cluster, :db)).to eq(
      server: nil, servers: ['replacement:6381'], cluster: nil, db: 2
    )
  end
end
