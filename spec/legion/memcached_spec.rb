# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memcached'

RSpec.describe Legion::Cache::Memcached do
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
