# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memory'
require 'timeout'

RSpec.describe Legion::Cache::Memory do
  before { described_class.reset! }
  after { described_class.reset! }

  describe '.get / .set' do
    it 'stores and retrieves a value' do
      described_class.set('key1', 'value1')
      expect(described_class.get('key1')).to eq('value1')
    end

    it 'returns nil for missing key' do
      expect(described_class.get('missing')).to be_nil
    end

    it 'expires values after TTL' do
      described_class.set('expire-me', 'data', ttl: 0.1)
      sleep 0.15
      expect(described_class.get('expire-me')).to be_nil
    end

    it 'clears stale expiry when a key is rewritten without TTL' do
      described_class.set('refresh-me', 'old', ttl: 0.05)
      described_class.set('refresh-me', 'new')
      sleep 0.06

      expect(described_class.get('refresh-me')).to eq('new')
    end

    it 'bounds stored entries using the configured capacity' do
      described_class.setup(max_entries: 2)
      described_class.set('first', 1)
      described_class.set('second', 2)
      described_class.set('third', 3)

      expect(described_class.mget('first', 'second', 'third')).to eq('first' => nil, 'second' => 2, 'third' => 3)
    end

    it 'treats zero TTL as no expiration' do
      described_class.set('persistent', 'value', ttl: 0)
      sleep 0.01

      expect(described_class.get('persistent')).to eq('value')
    end
  end

  describe '.delete' do
    it 'removes a key' do
      described_class.set('del-key', 'val')
      described_class.delete('del-key')
      expect(described_class.get('del-key')).to be_nil
    end
  end

  describe '.fetch' do
    it 'returns existing value' do
      described_class.set('f-key', 'existing')
      result = described_class.fetch('f-key') { 'fallback' } # rubocop:disable Style/RedundantFetchBlock
      expect(result).to eq('existing')
    end

    it 'stores and returns block value on miss' do
      result = described_class.fetch('f-miss') { 'computed' } # rubocop:disable Style/RedundantFetchBlock
      expect(result).to eq('computed')
      expect(described_class.get('f-miss')).to eq('computed')
    end

    it 'propagates application errors and leaves the key absent' do
      expect { described_class.fetch('broken') { raise ArgumentError, 'business failure' } }
        .to raise_error(ArgumentError, 'business failure')
      expect(described_class.get('broken')).to be_nil
    end

    it 'preserves the computed result when caching the result fails' do
      allow(described_class).to receive(:set).and_raise(IOError, 'cache unavailable')

      expect(described_class.fetch('computed') { 42 }).to eq(42)
    end
  end

  describe '.flush' do
    it 'clears all entries' do
      described_class.set('a', 1)
      described_class.set('b', 2)
      described_class.flush
      expect(described_class.get('a')).to be_nil
      expect(described_class.get('b')).to be_nil
    end
  end

  describe '.connected?' do
    it 'returns true after setup' do
      described_class.setup
      expect(described_class.connected?).to be true
    end
  end

  describe '.shutdown' do
    it 'marks as disconnected' do
      described_class.setup
      described_class.shutdown
      expect(described_class.connected?).to be false
    end
  end

  describe 'keyword ttl' do
    before { described_class.setup }

    it 'accepts ttl as keyword arg on set' do
      described_class.set('kw', 'val', ttl: 300)
      expect(described_class.get('kw')).to eq('val')
    end

    it 'accepts ttl as keyword arg on fetch' do
      result = described_class.fetch('fkw', ttl: 300) { 'fetched' }
      expect(result).to eq('fetched')
    end
  end


  describe 'thread safety' do
    it 'handles concurrent reads and writes' do
      described_class.setup
      threads = 20.times.map do |i|
        Thread.new do
          described_class.set("k#{i}", i)
          described_class.get("k#{i}")
        end
      end
      threads.each(&:join)
      expect(described_class.get('k0')).to eq(0)
    end
  end

  describe 'PHI retention' do
    before do
      allow(Legion::Settings).to receive(:dig).with(:cache, :compliance, :phi_max_ttl).and_return(0.5)
    end

    it 'enforces a positive bounded TTL across every write entrypoint' do
      store = described_class.instance_variable_get(:@store)
      allow(store).to receive(:monotonic_now).and_return(0)
      described_class.set('set', 'phi', phi: true)
      described_class.set_sync('sync', 'phi', ttl: 0, phi: true)
      described_class.set_nx('nx', 'phi', ttl: -1, phi: true)
      described_class.mset({ 'batch' => 'phi' }, ttl: 50, phi: true)
      described_class.mset_sync({ 'batch_sync' => 'phi' }, ttl: nil, phi: true)
      described_class.fetch('fetch', ttl: 0, phi: true) { 'phi' }
      keys = %w[set sync nx batch batch_sync fetch]
      expect(described_class.mget(keys).values).to eq(Array.new(keys.length, 'phi'))

      allow(store).to receive(:monotonic_now).and_return(0.5)
      expect(described_class.mget(keys).values).to eq(Array.new(keys.length))
    end

    it 'keeps a requested TTL shorter than the cap' do
      store = described_class.instance_variable_get(:@store)
      allow(store).to receive(:monotonic_now).and_return(0)
      described_class.set('short', 'phi', ttl: 0.1, phi: true)

      allow(store).to receive(:monotonic_now).and_return(0.1)
      expect(described_class.get('short')).to be_nil
    end

    it 'rejects a nonpositive configured cap instead of retaining PHI indefinitely' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :compliance, :phi_max_ttl).and_return(0)

      expect { described_class.set('invalid', 'phi', phi: true) }.to raise_error(ArgumentError)
      expect(described_class.get('invalid')).to be_nil
    end

    it 'rejects a nonfinite PHI TTL' do
      expect { described_class.set_nx('invalid', 'phi', ttl: Float::INFINITY, phi: true) }.to raise_error(ArgumentError)
      expect(described_class.get('invalid')).to be_nil
    end
  end
end

RSpec.describe Legion::Cache::ExpiringStore do
  subject(:store) { described_class.new(max_entries: 2) }

  after { store.close }

  it 'reclaims inactive expired entries without reads or writes' do
    store.set('inactive', Object.new, ttl: 0.01)

    Timeout.timeout(2) { sleep 0.01 until store.size.zero? }
    expect(store.size).to eq(0)
  end

  it 'reclaims expired entries before evicting live entries at capacity' do
    allow(store).to receive(:monotonic_now).and_return(0)
    store.set('live', 'keep')
    store.set('expired', 'discard', ttl: 1)
    allow(store).to receive(:monotonic_now).and_return(2)
    store.set('new', 'latest')

    expect(store.mget(%w[live expired new])).to eq('live' => 'keep', 'expired' => nil, 'new' => 'latest')
  end

  it 'stops cleanup promptly when closed even if the expiry clock is frozen' do
    allow(store).to receive(:monotonic_now).and_return(0)
    store.set('long-lived', 'value', ttl: 86_400)
    worker = store.instance_variable_get(:@cleanup_thread)

    Timeout.timeout(2) { store.close }
    expect(worker).not_to be_alive
    expect(store.size).to eq(0)
  end

  it 'stops cleanup once the last expiration is removed and restarts on demand' do
    store.set('key', 'value', ttl: 86_400)
    worker = store.instance_variable_get(:@cleanup_thread)
    store.set('key', 'persistent')
    expect(worker.join(2)).to eq(worker)

    store.set('short-lived', 'value', ttl: 0.01)
    Timeout.timeout(2) { sleep 0.01 until store.size == 1 }
    expect(store.get('key')).to eq('persistent')
    expect(store.get('short-lived')).to be_nil
  end
end
