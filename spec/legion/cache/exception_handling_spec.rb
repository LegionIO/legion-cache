# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'
require 'legion/cache/memory'
require 'legion/cache/memcached'
require 'legion/cache/redis'

RSpec.describe 'exception handling' do
  describe Legion::Cache::Memory do
    before { described_class.setup }
    after { described_class.reset! }

    describe 'reads return nil on error' do
      it 'get returns nil when store raises' do
        allow(described_class).to receive(:expire_if_needed).and_raise(RuntimeError, 'boom')
        expect(described_class.get('key')).to be_nil
      end
    end

    describe 'sync writes re-raise' do
      it 'set_sync raises on error' do
        allow(described_class.instance_variable_get(:@store)).to receive(:[]=).and_raise(RuntimeError, 'boom')
        expect { described_class.set_sync('k', 'v', ttl: 60) }.to raise_error(RuntimeError, 'boom')
      end
    end

    describe 'flush handles errors internally' do
      it 'flush returns false on error' do
        store = described_class.instance_variable_get(:@store)
        allow(store).to receive(:clear).and_raise(RuntimeError, 'boom')
        expect(described_class.flush).to be(false)
        allow(store).to receive(:clear).and_call_original
      end
    end
  end

  describe Legion::Cache::Memcached do
    let(:cache) { described_class.dup }
    let(:pool) { instance_double(ConnectionPool) }
    let(:dalli) { instance_double(Dalli::Client) }

    before do
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)
      allow(pool).to receive(:with).and_yield(dalli)
    end

    it 'get returns nil on error' do
      allow(dalli).to receive(:get).and_raise(StandardError, 'timeout')
      expect(cache.get('k')).to be_nil
    end

    it 'set_sync re-raises on error' do
      allow(dalli).to receive(:set).and_raise(StandardError, 'timeout')
      expect { cache.set_sync('k', 'v', ttl: 60) }.to raise_error(StandardError, 'timeout')
    end

    it 'delete_sync re-raises on error' do
      allow(dalli).to receive(:delete).and_raise(StandardError, 'timeout')
      expect { cache.delete_sync('k') }.to raise_error(StandardError, 'timeout')
    end
  end

  describe Legion::Cache::Redis do
    let(:cache) { described_class.dup }
    let(:pool) { instance_double(ConnectionPool) }
    let(:redis) { instance_double(Redis) }

    before do
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)
      allow(pool).to receive(:with).and_yield(redis)
    end

    it 'get returns nil on error' do
      allow(redis).to receive(:get).and_raise(StandardError, 'timeout')
      expect(cache.get('k')).to be_nil
    end

    it 'set_sync re-raises on error' do
      allow(redis).to receive(:set).and_raise(StandardError, 'timeout')
      expect { cache.set_sync('k', 'v', ttl: 60) }.to raise_error(StandardError, 'timeout')
    end

    it 'delete_sync re-raises on error' do
      allow(redis).to receive(:del).and_raise(StandardError, 'timeout')
      expect { cache.delete_sync('k') }.to raise_error(StandardError, 'timeout')
    end
  end
end

RSpec.describe 'Legion::Cache top-level exception handling' do
  before do
    ENV['LEGION_MODE'] = 'lite'
    Legion::Cache::Memory.setup
    Legion::Cache.instance_variable_set(:@using_memory, true)
    Legion::Cache.instance_variable_set(:@connected, true)
  end

  after do
    ENV.delete('LEGION_MODE')
    Legion::Cache::Memory.reset!
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@connected, false)
  end

  it 'get returns nil on internal error' do
    allow(Legion::Cache::Memory).to receive(:get).and_raise(RuntimeError, 'boom')
    expect(Legion::Cache.get('key')).to be_nil
  end

  it 'set with async: false re-raises on error from Memory' do
    allow(Legion::Cache::Memory).to receive(:set).and_raise(RuntimeError, 'boom')
    expect { Legion::Cache.set('k', 'v', ttl: 60, async: false) }.to raise_error(RuntimeError, 'boom')
  end
end
