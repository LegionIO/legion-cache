# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'
require 'legion/cache/local'

RSpec.describe Legion::Cache::Local do
  describe 'module interface' do
    it 'responds to setup' do
      expect(described_class).to respond_to(:setup)
    end

    it 'responds to shutdown' do
      expect(described_class).to respond_to(:shutdown)
    end

    it 'responds to connected?' do
      expect(described_class).to respond_to(:connected?)
    end

    it 'responds to get' do
      expect(described_class).to respond_to(:get)
    end

    it 'responds to set' do
      expect(described_class).to respond_to(:set)
    end

    it 'responds to delete' do
      expect(described_class).to respond_to(:delete)
    end

    it 'responds to flush' do
      expect(described_class).to respond_to(:flush)
    end

    it 'responds to fetch' do
      expect(described_class).to respond_to(:fetch)
    end

    it 'responds to client' do
      expect(described_class).to respond_to(:client)
    end

    it 'responds to reset!' do
      expect(described_class).to respond_to(:reset!)
    end

    it 'responds to close' do
      expect(described_class).to respond_to(:close)
    end

    it 'responds to restart' do
      expect(described_class).to respond_to(:restart)
    end

    it 'responds to size' do
      expect(described_class).to respond_to(:size)
    end

    it 'responds to available' do
      expect(described_class).to respond_to(:available)
    end

    it 'responds to pool_size' do
      expect(described_class).to respond_to(:pool_size)
    end

    it 'responds to timeout' do
      expect(described_class).to respond_to(:timeout)
    end
  end

  describe 'not connected' do
    before { described_class.reset! }

    it 'reports not connected' do
      expect(described_class.connected?).to eq false
    end
  end
end

RSpec.describe 'Legion::Cache::Local integration', :integration do
  before(:all) do
    Legion::Cache::Local.reset!
    Legion::Cache::Local.setup
  end

  after(:all) do
    Legion::Cache::Local.shutdown
  end

  it 'can setup and connect' do
    expect(Legion::Cache::Local.connected?).to eq true
  end

  it 'can set and get' do
    expect(Legion::Cache::Local.set('local_test', 'hello')).to eq true
    expect(Legion::Cache::Local.get('local_test')).to eq 'hello'
  end

  it 'can set with TTL' do
    expect(Legion::Cache::Local.set('local_ttl', 'expires', 10)).to eq true
    expect(Legion::Cache::Local.get('local_ttl')).to eq 'expires'
  end

  it 'can delete' do
    Legion::Cache::Local.set('local_del', 'gone')
    expect(Legion::Cache::Local.delete('local_del')).to eq true
    expect(Legion::Cache::Local.get('local_del')).to be_nil
  end

  it 'can flush' do
    Legion::Cache::Local.set('local_flush', 'bye')
    expect(Legion::Cache::Local.flush).to eq true
  end

  it 'can report size and available' do
    expect(Legion::Cache::Local.size).to eq 5
    expect(Legion::Cache::Local.available).to be_a(Integer)
  end

  it 'can report pool_size and timeout' do
    expect(Legion::Cache::Local.pool_size).to eq 5
    expect(Legion::Cache::Local.timeout).to eq 3
  end

  it 'can shutdown and reconnect' do
    Legion::Cache::Local.shutdown
    expect(Legion::Cache::Local.connected?).to eq false
    Legion::Cache::Local.setup
    expect(Legion::Cache::Local.connected?).to eq true
  end

  it 'can restart with new values' do
    Legion::Cache::Local.restart(pool_size: 2, timeout: 1)
    expect(Legion::Cache::Local.connected?).to eq true
    expect(Legion::Cache::Local.set('restart_test', 'works')).to eq true
    expect(Legion::Cache::Local.get('restart_test')).to eq 'works'
  end

  it 'uses separate namespace from shared cache' do
    Legion::Cache::Local.set('ns_test', 'local_value')
    Legion::Cache.setup
    Legion::Cache.set('ns_test', 'shared_value')
    expect(Legion::Cache::Local.get('ns_test')).to eq 'local_value'
    expect(Legion::Cache.get('ns_test')).to eq 'shared_value'
    Legion::Cache.shutdown
  end
end
