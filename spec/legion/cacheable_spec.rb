# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/cacheable'

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
