# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memcached'

RSpec.describe Legion::Cache::Memcached do
  describe 'method signatures' do
    it 'set accepts keyword ttl' do
      cache = described_class.dup
      pool = instance_double(ConnectionPool)
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)

      dalli = instance_double(Dalli::Client)
      allow(pool).to receive(:with).and_yield(dalli)
      allow(dalli).to receive(:set).and_return(1)

      expect { cache.set('k', 'v', ttl: 120) }.not_to raise_error
    end

    it 'flush takes no arguments' do
      expect(described_class.method(:flush).arity).to eq(0)
    end

    it 'uses log instead of cache_logger' do
      expect(described_class.private_method_defined?(:cache_logger)).to be(false)
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
