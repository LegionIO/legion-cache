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

      it 'preserves cached false values from Local' do
        allow(Legion::Cache::Local).to receive(:get).with('local.false').and_return(false)
        described_class.memory_write('local.false', 'fallback', 60)

        expect(described_class.cache_read('local.false', scope: :local)).to be(false)
      end

      it 'falls back to memory when Local reads raise' do
        allow(Legion::Cache::Local).to receive(:get).with('local.error').and_raise(StandardError, 'boom')
        described_class.memory_write('local.error', 'fallback', 60)

        expect(described_class.cache_read('local.error', scope: :local)).to eq('fallback')
      end

      it 'writes to Local cache' do
        described_class.cache_write('local.w', 'data', ttl: 60, scope: :local)
        expect(Legion::Cache::Local).to have_received(:set).with('local.w', 'data', ttl: 60)
      end

      it 'falls back to memory when Local writes raise' do
        allow(Legion::Cache::Local).to receive(:set).with('local.error', 'data', ttl: 60).and_raise(StandardError, 'boom')

        described_class.cache_write('local.error', 'data', ttl: 60, scope: :local)
        expect(described_class.memory_read('local.error')).to eq('data')
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
        expect(Legion::Cache).to have_received(:set).with('global.w', 'data', ttl: 120, async: false)
      end
    end
  end
end

RSpec.describe Legion::Cache::Cacheable, 'cache_method DSL' do
  before { Legion::Cache::Cacheable.memory_clear! }

  let(:test_module) do
    Module.new do
      def self.name
        'TestRunner'
      end

      extend Legion::Cache::Cacheable

      def fetch_data(user_id: 'me', **)
        { user_id: user_id, fetched_at: Time.now.utc.to_f }
      end

      cache_method :fetch_data, ttl: 60
    end
  end

  let(:instance) { Object.new.extend(test_module) }

  describe 'caching behavior' do
    it 'returns cached result on second call' do
      first = instance.fetch_data(user_id: 'alice')
      second = instance.fetch_data(user_id: 'alice')
      expect(second[:fetched_at]).to eq(first[:fetched_at])
    end

    it 'caches separately for different args' do
      alice = instance.fetch_data(user_id: 'alice')
      bob = instance.fetch_data(user_id: 'bob')
      expect(alice[:user_id]).to eq('alice')
      expect(bob[:user_id]).to eq('bob')
      expect(alice[:fetched_at]).not_to eq(bob[:fetched_at])
    end

    it 'does not cache across different method calls' do
      mod = Module.new do
        def self.name
          'MultiMethod'
        end

        extend Legion::Cache::Cacheable

        def method_a(**)
          { method: :a, t: Time.now.utc.to_f }
        end

        def method_b(**)
          { method: :b, t: Time.now.utc.to_f }
        end

        cache_method :method_a, ttl: 60
        cache_method :method_b, ttl: 60
      end
      obj = Object.new.extend(mod)
      a = obj.method_a
      b = obj.method_b
      expect(a[:method]).to eq(:a)
      expect(b[:method]).to eq(:b)
    end

    it 'falls back to memory when the local backend is connected but failing' do
      allow(Legion::Cache::Cacheable).to receive(:local_cache_available?).and_return(true)
      allow(Legion::Cache::Local).to receive(:get).and_raise(StandardError, 'read failed')
      allow(Legion::Cache::Local).to receive(:set).and_raise(StandardError, 'write failed')

      first = instance.fetch_data(user_id: 'alice')
      second = instance.fetch_data(user_id: 'alice')

      expect(second[:fetched_at]).to eq(first[:fetched_at])
    end
  end

  describe 'bypass_local_method_cache' do
    it 'skips cache read and refreshes on bypass' do
      first = instance.fetch_data(user_id: 'me')
      bypassed = instance.fetch_data(user_id: 'me', bypass_local_method_cache: true)
      expect(bypassed[:fetched_at]).not_to eq(first[:fetched_at])
    end

    it 'writes result back to cache after bypass' do
      instance.fetch_data(user_id: 'me')
      bypassed = instance.fetch_data(user_id: 'me', bypass_local_method_cache: true)
      cached = instance.fetch_data(user_id: 'me')
      expect(cached[:fetched_at]).to eq(bypassed[:fetched_at])
    end
  end

  describe 'exclude_from_key' do
    let(:token_module) do
      Module.new do
        def self.name
          'TokenRunner'
        end

        extend Legion::Cache::Cacheable

        def get_thing(id:, token: nil, **) # rubocop:disable Lint/UnusedMethodArgument
          { id: id, t: Time.now.utc.to_f }
        end

        cache_method :get_thing, ttl: 60, exclude_from_key: [:token]
      end
    end

    let(:token_instance) { Object.new.extend(token_module) }

    it 'ignores excluded args when building cache key' do
      first = token_instance.get_thing(id: 1, token: 'abc')
      second = token_instance.get_thing(id: 1, token: 'xyz')
      expect(second[:t]).to eq(first[:t])
    end
  end

  describe 'cached_methods registry' do
    it 'tracks declared cached methods' do
      expect(test_module.cached_methods).to have_key(:fetch_data)
      expect(test_module.cached_methods[:fetch_data][:ttl]).to eq(60)
    end
  end
end

RSpec.describe 'Cacheable autoload' do
  it 'is accessible after requiring legion/cache' do
    require 'legion/cache'
    expect(Legion::Cache::Cacheable).to be_a(Module)
    expect(Legion::Cache::Cacheable).to respond_to(:cache_read)
    expect(Legion::Cache::Cacheable).to respond_to(:build_cache_key)
    expect(Legion::Cache::Cacheable).to respond_to(:memory_clear!)
  end
end
