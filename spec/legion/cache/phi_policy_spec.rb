# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'PHI retention on public write routes' do
  before do
    Legion::Cache.shutdown
    @mode = ENV.fetch('LEGION_MODE', nil)
    @settings = Legion::Settings[:cache].dup
    @local_settings = Legion::Settings[:cache_local].dup
    ENV['LEGION_MODE'] = 'lite'
    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:compliance] = { phi_max_ttl: 60 }
    Legion::Settings[:cache_local][:enabled] = true
    @now = 1000.0
    allow(Legion::Cache::Memory.instance_variable_get(:@store)).to receive(:monotonic_now) { @now }
    Legion::Cache.setup
    allow(Legion::Cache::Local).to receive(:build_driver).and_return(Legion::Cache::Memory)
    Legion::Cache::Local.setup
  end

  after do
    Legion::Cache.shutdown
    Legion::Settings[:cache].replace(@settings)
    Legion::Settings[:cache_local].replace(@local_settings)
    @mode ? ENV['LEGION_MODE'] = @mode : ENV.delete('LEGION_MODE')
  end

  [Legion::Cache, Legion::Cache::Local].each do |cache|
    it "expires PHI for all synchronous #{cache} write routes, including immortal TTL requests" do
      cache.set('set', 'private', ttl: 0, phi: true, async: false)
      cache.set_sync('sync', 'private', ttl: -1, phi: true)
      cache.mset({ 'batch' => 'private' }, ttl: 7200, phi: true, async: false)
      cache.mset_sync({ 'batch_sync' => 'private' }, ttl: 0, phi: true)
      cache.set_nx('nx', 'private', ttl: 0, phi: true)
      cache.cas('cas', ttl: 0, phi: true) { 'private' }
      cache.set_sync('ordinary', 'public', ttl: 0)

      %w[set sync batch batch_sync nx cas].each { |key| expect(cache.get(key)).to eq('private') }
      @now += 61
      %w[set sync batch batch_sync nx cas].each { |key| expect(cache.get(key)).to be_nil }
      expect(cache.get('ordinary')).to eq('public')
    end

    it "retains the PHI cap through asynchronous #{cache} admission" do
      expect(cache.set('async', 'private', ttl: 0, phi: true)).to be(true)
      expect(cache.mset({ 'async_batch' => 'private' }, ttl: 7200, phi: true)).to be(true)
      cache.instance_variable_get(:@async_writer).stop

      expect(cache.get('async')).to eq('private')
      expect(cache.get('async_batch')).to eq('private')
      @now += 61
      expect(cache.get('async')).to be_nil
      expect(cache.get('async_batch')).to be_nil
    end
  end

  it 'rejects invalid PHI caps instead of creating unbounded entries' do
    Legion::Settings[:cache][:compliance] = { phi_max_ttl: 0 }
    expect { Legion::Cache.set_sync('private', 'value', phi: true) }.to raise_error(ArgumentError)
    expect(Legion::Cache.get('private')).to be_nil
  end
end
