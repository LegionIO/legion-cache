# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memcached'
require 'concurrent/atomic/atomic_boolean'

RSpec.describe Legion::Cache::Memcached do
  let(:cache) { described_class.dup }
  let(:dalli) { instance_double(Dalli::Client) }
  let(:pool) { ConnectionPool.new(size: 1, timeout: 0.05) { dalli } }

  before { cache.instance_variable_set(:@client, pool) }

  describe '#fetch' do
    it 'releases the only connection before computing a nested cache miss' do
      allow(dalli).to receive(:get).with('outer').and_return(nil)
      allow(dalli).to receive(:get).with('inner').and_return('nested')
      allow(dalli).to receive(:add).and_return(42)

      expect(cache.fetch('outer') { cache.get('inner') }).to eq('nested')
    end

    it 'returns cached false without evaluating the caller block' do
      allow(dalli).to receive(:get).and_return(false)

      expect(cache.fetch('flag') { raise 'should not execute' }).to be(false)
    end

    it 'propagates application errors unchanged' do
      allow(dalli).to receive(:get).and_return(nil)
      error = IOError.new('application failure')

      expect { cache.fetch('key') { raise error } }.to(raise_error { |raised| expect(raised).to equal(error) })
    end

    it 'returns the computed value when the backend write fails' do
      allow(dalli).to receive(:get).and_return(nil)
      allow(dalli).to receive(:add).and_raise(Dalli::RingError, 'offline')

      expect(cache.fetch('key') { 'computed' }).to eq('computed') # rubocop:disable Style/RedundantFetchBlock
    end
  end

  describe '#set_nx' do
    it 'reports a successful Dalli CAS token as true' do
      allow(dalli).to receive(:add).and_return(42, false)

      expect(cache.set_nx('key', 'first')).to be(true)
      expect(cache.set_nx('key', 'second')).to be(false)
    end
  end

  describe '#set' do
    it 'returns false when Dalli rejects a write' do
      allow(dalli).to receive(:set).and_return(false)

      expect(cache.set('key', 'value')).to be(false)
    end
  end

  describe '#mset' do
    it 'reports rejection while still writing remaining keys' do
      stored = {}
      allow(dalli).to receive(:set) do |key, value, _ttl|
        next false if key == 'rejected'

        stored[key] = value
        42
      end

      expect(cache.mset({ 'rejected' => 1, 'accepted' => 2 })).to be(false)
      expect(stored).to eq('accepted' => 2)
    end

    it 'expires all entries using the requested TTL' do
      expires = {}
      now = 0
      allow(dalli).to receive(:set) do |key, _value, ttl|
        expires[key] = now + ttl
        42
      end
      allow(dalli).to receive(:get) { |key| 'cached' if expires[key] && now < expires[key] }

      expect(cache.mset({ 'first' => 1, 'second' => 2 }, ttl: 10)).to be(true)
      now = 9
      expect(cache.get('first')).to eq('cached')
      now = 10
      expect(cache.get('first')).to be_nil
      expect(cache.get('second')).to be_nil
    end

    it 'uses the configured default TTL when none is supplied' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :default_ttl).and_return(20)
      expires = nil
      now = 19
      allow(dalli).to receive(:set) { |_key, _value, ttl| expires = ttl }
      allow(dalli).to receive(:get) { |_key| 'cached' if expires && now < expires }

      expect(cache.mset({ 'key' => 1 })).to be(true)
      expect(cache.get('key')).to eq('cached')
      now = 20
      expect(cache.get('key')).to be_nil
    end
  end

  describe '#cas' do
    let(:values) { {} }
    let(:tokens) { {} }

    before do
      sequence = 0
      allow(dalli).to receive(:get_cas) { |key| [values[key], tokens[key]] }
      allow(dalli).to receive(:get) { |key| values[key] }
      allow(dalli).to receive(:add) do |key, value, _ttl|
        next false if tokens.key?(key)

        values[key] = value
        tokens[key] = (sequence += 1)
      end
      allow(dalli).to receive(:set_cas) do |key, value, token, _ttl|
        next false unless tokens[key] == token

        values[key] = value
        tokens[key] = (sequence += 1)
      end
    end

    it 'retries an absent-key race without overwriting the competing update' do
      competed = false
      result = cache.cas('hash') do |current|
        unless competed
          competed = true
          cache.cas('hash') { { 'other' => 1 } }
        end
        (current || {}).merge('ours' => 2)
      end

      expect(result).to eq('other' => 1, 'ours' => 2)
      expect(cache.get('hash')).to eq(result)
    end

    it 'retries a stale CAS token after an existing-key update' do
      cache.cas('counter') { 1 }
      competed = false
      result = cache.cas('counter') do |current|
        unless competed
          competed = true
          cache.cas('counter') { |value| value + 1 }
        end
        current + 1
      end

      expect(result).to eq(3)
      expect(cache.get('counter')).to eq(3)
    end

    it 'updates a stored nil using its CAS token rather than add' do
      cache.cas('nullable') { nil }

      expect(cache.cas('nullable') { |current| !current.nil? }).to be(false)
      expect(cache.get('nullable')).to be(false)
    end

    it 'fails boundedly when every attempted update is rejected' do
      allow(dalli).to receive(:add).and_return(false)

      expect { cache.cas('contended') { 'value' } }.to raise_error(RuntimeError, /retry limit/)
      expect(cache.get('contended')).to be_nil
    end

    it 'propagates application errors without committing an update' do
      cache.cas('counter') { 1 }

      expect { cache.cas('counter') { raise IOError, 'application failure' } }.to raise_error(IOError, 'application failure')
      expect(cache.get('counter')).to eq(1)
    end
  end

  describe 'backend health' do
    before { cache.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(true)) }

    it 'marks handled read connection failures disconnected' do
      allow(dalli).to receive(:get).and_raise(Dalli::RingError, 'offline')

      expect(cache.get('key')).to be_nil
      expect(cache.connected?).to be(false)
      expect(cache.instance_variable_get(:@connected)).to be_a(Concurrent::AtomicBoolean)
    end

    it 'does not treat a caller IO error as a backend failure' do
      allow(dalli).to receive(:get).and_return(nil)

      expect { cache.fetch('key') { raise IOError, 'application failure' } }.to raise_error(IOError, 'application failure')
      expect(cache.connected?).to be(true)
    end

    it 'does not mark a rejected oversized value as disconnected' do
      allow(dalli).to receive(:set).and_raise(Dalli::ValueOverMaxSize, 'oversized')

      expect { cache.set('key', 'value') }.to raise_error(Dalli::ValueOverMaxSize)
      expect(cache.connected?).to be(true)
    end
  end

  describe '#client' do
    before { cache.instance_variable_set(:@client, nil) }

    it 'discards and closes a failed health-check pool before retrying setup' do
      failed = instance_double(Dalli::Client, close: nil)
      healthy = instance_double(Dalli::Client, alive!: true, get: 'healthy')
      allow(failed).to receive(:alive!).and_raise(Dalli::RingError, 'offline')
      allow(Dalli::Client).to receive(:new).and_return(failed, healthy)

      expect { cache.client }.to raise_error(Dalli::RingError)
      expect(cache.connected?).to be(false)
      expect(failed).to have_received(:close)
      cache.client
      expect(cache.connected?).to be(true)
      expect(cache.get('key')).to eq('healthy')
    end

    it 'bounds a stalled backend health check and closes its connection' do
      stalled = instance_double(Dalli::Client, close: nil)
      allow(stalled).to receive(:alive!) { sleep 60 }
      allow(Dalli::Client).to receive(:new).and_return(stalled)

      expect { cache.client(timeout: 0.01) }.to raise_error(Timeout::Error)
      expect(cache.connected?).to be(false)
      expect(stalled).to have_received(:close)
    end
  end
end

RSpec.describe Legion::Cache::Memcached, :integration do
  before(:all) do
    @cache = Legion::Cache::Memcached
  end

  it 'can connect' do
    expect(@cache).not_to respond_to :connect
    expect { @cache.client }.not_to raise_exception
    expect(@cache.connected?).to eq true
  end

  it 'can close' do
    expect(@cache).to respond_to :close

    expect { @cache.close }.not_to raise_error
  end

  it 'can restart' do
    expect(@cache).to respond_to :restart

    expect { @cache.restart }.not_to raise_error
  end

  it 'can set' do
    expect(@cache).to respond_to :set
    expect(@cache.set('foo', 'bar')).to eq true
    expect(@cache.set('baz', 'world', ttl: 10)).to eq true
  end

  it 'can get' do
    expect(@cache).to respond_to :get

    expect(@cache.get('foo')).to eq 'bar'
  end

  it 'can fetch' do
    expect(@cache).to respond_to :fetch

    expect(@cache.fetch('foo')).to eq 'bar'
  end

  it 'can delete' do
    expect(@cache).to respond_to :delete

    expect(@cache.delete('foo')).to eq true
  end

  it 'can flush' do
    expect(@cache).to respond_to :flush
    expect(@cache.flush).to eq true
  end

  it 'accepts singular server parameter' do
    @cache.close if @cache.connected?
    @cache.instance_variable_set(:@client, nil)
    @cache.instance_variable_set(:@connected, false)
    expect { @cache.client(server: '127.0.0.1') }.not_to raise_error
    expect(@cache.connected?).to eq true
  end

  it 'wont use bogus methods' do
    expect(@cache).not_to respond_to :this_is_fake
  end

  it 'can become an object' do
    memcached = Legion::Cache::Memcached
    expect(memcached.object_id).to eq memcached.object_id
    expect(memcached.client).to eq memcached.client
    expect(memcached.connected?).to eq true
  end
end
