# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memcached'

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

      expect { cache.fetch('key') { raise error } }.to raise_error { |raised| expect(raised).to equal(error) }
    end

    it 'returns the computed value when the backend write fails' do
      allow(dalli).to receive(:get).and_return(nil)
      allow(dalli).to receive(:add).and_raise(Dalli::RingError, 'offline')

      expect(cache.fetch('key') { 'computed' }).to eq('computed')
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
    expect(@cache.set('baz', 'world', 10)).to eq true
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
