# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'disabled cache operations' do
  before do
    Legion::Cache.shutdown
    @cache_enabled = Legion::Settings[:cache][:enabled]
    @local_enabled = Legion::Settings[:cache_local][:enabled]
    Legion::Settings[:cache][:enabled] = false
    Legion::Settings[:cache_local][:enabled] = false
  end

  after do
    Legion::Settings[:cache][:enabled] = @cache_enabled
    Legion::Settings[:cache_local][:enabled] = @local_enabled
  end

  [Legion::Cache, Legion::Cache::Local].each do |cache|
    it "does not connect, admit mutations or evaluate cas for disabled #{cache}" do
      expect(cache.setup).to be(false)
      expect(cache.client).to be_nil
      expect(cache.restart).to be(false)
      expect(cache.connected?).to be(false)
      expect(cache.get('key')).to be_nil
      expect(cache.mget('key')).to eq({})
      expect(cache.set('key', 'value')).to be(false)
      expect(cache.set_sync('key', 'value')).to be(false)
      expect(cache.set_nx('key', 'value')).to be(false)
      expect(cache.mset({ 'key' => 'value' })).to be(false)
      expect(cache.mset_sync({ 'key' => 'value' })).to be(false)
      expect(cache.delete('key')).to be(false)
      expect(cache.delete_sync('key')).to be(false)
      expect(cache.flush).to be(false)
      expect(cache.cas('key') { raise 'must not run' }).to be(false)
      expect(cache.fetch('key') { 'computed' }).to eq('computed')
      expect(cache.get('key')).to be_nil
    end
  end
end
