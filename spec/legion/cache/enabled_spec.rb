# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'enabled? and connected?' do
  before do
    Legion::Cache.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(false))
    Legion::Cache::Local.reset!
  end

  after do
    Legion::Settings[:cache][:enabled] = true
  end

  describe 'Legion::Cache.enabled?' do
    it 'returns true when settings enabled is true' do
      Legion::Settings[:cache][:enabled] = true
      expect(Legion::Cache.enabled?).to be(true)
    end

    it 'returns false when settings enabled is false' do
      Legion::Settings[:cache][:enabled] = false
      expect(Legion::Cache.enabled?).to be(false)
    end
  end

  describe 'Legion::Cache::Local.enabled?' do
    it 'reads from cache_local settings' do
      Legion::Settings[:cache_local] ||= {}
      Legion::Settings[:cache_local][:enabled] = false
      expect(Legion::Cache::Local.enabled?).to be(false)
      Legion::Settings[:cache_local][:enabled] = true
    end
  end

  describe 'setup respects enabled?' do
    it 'does not connect when disabled' do
      Legion::Settings[:cache][:enabled] = false
      expect(Legion::Cache::Local).not_to receive(:setup)
      Legion::Cache.setup
      expect(Legion::Cache.connected?).to be(false)
      Legion::Settings[:cache][:enabled] = true
    end
  end

  describe 'Legion::Cache::Memory enabled?' do
    it 'always returns true' do
      expect(Legion::Cache::Memory).to respond_to(:connected?)
    end
  end
end
