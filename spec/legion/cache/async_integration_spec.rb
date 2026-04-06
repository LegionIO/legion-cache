# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'async write integration' do
  before do
    ENV['LEGION_MODE'] = 'lite'
    Legion::Cache.setup
  end

  after do
    Legion::Cache.shutdown
    ENV.delete('LEGION_MODE')
  end

  it 'set with async: true returns true immediately' do
    expect(Legion::Cache.set('async_key', 'val', async: true)).to be(true)
  end

  it 'set with async: false writes synchronously' do
    Legion::Cache.set('sync_key', 'val', async: false)
    expect(Legion::Cache.get('sync_key')).to eq('val')
  end

  it 'set with async: true eventually writes the value' do
    Legion::Cache.set('eventual', 'val', async: true)
    sleep 0.2
    expect(Legion::Cache.get('eventual')).to eq('val')
  end

  it 'stats reports async pool size' do
    stats = Legion::Cache.stats
    expect(stats[:async_pool_size]).to be_a(Integer)
    expect(stats[:async_pool_size]).to be > 0
  end
end
