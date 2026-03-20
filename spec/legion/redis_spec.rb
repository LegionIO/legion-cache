# frozen_string_literal: true

require 'legion/cache/redis'

RSpec.describe Legion::Cache::Redis do
  before(:all) do
    @cache = Legion::Cache::Redis
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
    expect(@cache.set('test', 'test')).to eq true
  end

  it 'can get' do
    expect(@cache).to respond_to :get
    expect(@cache.get('test')).to eq 'test'
  end

  it 'can fetch' do
    expect(@cache.respond_to?(:fetch)).to eq true
    expect(@cache.fetch('test')).to eq 'test'
  end

  it 'can delete' do
    expect(@cache).to respond_to :delete
    expect(@cache.delete('test')).to eq true
  end

  it 'can flush' do
    expect(@cache).to respond_to :flush
    expect(@cache.flush).to eq true
  end

  it 'accepts servers parameter' do
    @cache.close if @cache.connected?
    @cache.instance_variable_set(:@client, nil)
    @cache.instance_variable_set(:@connected, false)
    expect { @cache.client(servers: ['127.0.0.1:6379']) }.not_to raise_error
    expect(@cache.connected?).to eq true
  end

  it 'wont use bogus methods' do
    expect(@cache).not_to respond_to :this_is_fake
  end
end
