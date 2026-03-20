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
