# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/cacheable'
require 'legion/cache/local'

RSpec.describe Legion::Cache::Cacheable do
  before { described_class.memory_clear! }

  describe '.memory_write and .memory_read' do
    it 'stores and retrieves a value' do
      described_class.memory_write('test.key', { status: 'ok' }, 60)
      expect(described_class.memory_read('test.key')).to eq({ status: 'ok' })
    end

    it 'returns nil for missing keys' do
      expect(described_class.memory_read('missing')).to be_nil
    end

    it 'returns nil for expired entries' do
      described_class.memory_write('expired', 'old', 0)
      sleep 0.01
      expect(described_class.memory_read('expired')).to be_nil
    end

    it 'overwrites existing entries' do
      described_class.memory_write('key', 'first', 60)
      described_class.memory_write('key', 'second', 60)
      expect(described_class.memory_read('key')).to eq('second')
    end
  end

  describe '.memory_clear!' do
    it 'removes all entries' do
      described_class.memory_write('a', 1, 60)
      described_class.memory_write('b', 2, 60)
      described_class.memory_clear!
      expect(described_class.memory_read('a')).to be_nil
      expect(described_class.memory_read('b')).to be_nil
    end
  end
end

RSpec.describe Legion::Cache::Cacheable, '.build_cache_key' do
  it 'produces a key with module path, method name, and args hash' do
    key = described_class.build_cache_key('MyModule', :my_method, exclude: [], user_id: 'me')
    expect(key).to match(/\AMyModule\.my_method\.[a-f0-9]{32}\z/)
  end

  it 'excludes filtered args from the hash' do
    key_with = described_class.build_cache_key('M', :m, exclude: [:token], user_id: 'me', token: 'secret')
    key_without = described_class.build_cache_key('M', :m, exclude: [:token], user_id: 'me')
    expect(key_with).to eq(key_without)
  end

  it 'produces different keys for different args' do
    key_a = described_class.build_cache_key('M', :m, exclude: [], user_id: 'alice')
    key_b = described_class.build_cache_key('M', :m, exclude: [], user_id: 'bob')
    expect(key_a).not_to eq(key_b)
  end

  it 'produces a deterministic key for the same args regardless of order' do
    key_a = described_class.build_cache_key('M', :m, exclude: [], b: 2, a: 1)
    key_b = described_class.build_cache_key('M', :m, exclude: [], a: 1, b: 2)
    expect(key_a).to eq(key_b)
  end

  it 'handles empty kwargs' do
    key = described_class.build_cache_key('M', :m, exclude: [])
    expect(key).to match(/\AM\.m\.[a-f0-9]{32}\z/)
  end
end

RSpec.describe Legion::Cache::Cacheable, 'cache_read and cache_write' do
  before { described_class.memory_clear! }

  describe 'local scope' do
    context 'when Legion::Cache::Local is not available' do
      before do
        allow(described_class).to receive(:local_cache_available?).and_return(false)
      end

      it 'falls back to memory store' do
        described_class.cache_write('local.key', 'value', ttl: 30, scope: :local)
        expect(described_class.cache_read('local.key', scope: :local)).to eq('value')
      end
    end

    context 'when Legion::Cache::Local is available' do
      before do
        allow(described_class).to receive(:local_cache_available?).and_return(true)
        allow(Legion::Cache::Local).to receive(:get).with('local.hit').and_return('cached')
        allow(Legion::Cache::Local).to receive(:get).with('local.miss').and_return(nil)
        allow(Legion::Cache::Local).to receive(:set)
      end

      it 'reads from Local cache' do
        expect(described_class.cache_read('local.hit', scope: :local)).to eq('cached')
      end

      it 'falls through to memory on Local miss' do
        described_class.memory_write('local.miss', 'fallback', 60)
        expect(described_class.cache_read('local.miss', scope: :local)).to eq('fallback')
      end

      it 'writes to Local cache' do
        described_class.cache_write('local.w', 'data', ttl: 60, scope: :local)
        expect(Legion::Cache::Local).to have_received(:set).with('local.w', 'data', 60)
      end
    end
  end

  describe 'global scope' do
    context 'when global cache is not available' do
      before do
        allow(described_class).to receive(:global_cache_available?).and_return(false)
      end

      it 'falls back to memory store' do
        described_class.cache_write('global.key', 'value', ttl: 30, scope: :global)
        expect(described_class.cache_read('global.key', scope: :global)).to eq('value')
      end
    end

    context 'when global cache is available' do
      before do
        allow(described_class).to receive(:global_cache_available?).and_return(true)
        allow(Legion::Cache).to receive(:get).with('global.hit').and_return('remote')
        allow(Legion::Cache).to receive(:set)
      end

      it 'reads from global cache' do
        expect(described_class.cache_read('global.hit', scope: :global)).to eq('remote')
      end

      it 'writes to global cache' do
        described_class.cache_write('global.w', 'data', ttl: 120, scope: :global)
        expect(Legion::Cache).to have_received(:set).with('global.w', 'data', 120)
      end
    end
  end
end
