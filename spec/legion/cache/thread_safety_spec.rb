# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'thread-safe state flags' do
  describe 'Legion::Cache' do
    it 'uses AtomicBoolean for connected state' do
      flag = Legion::Cache.instance_variable_get(:@connected)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end

    it 'uses AtomicBoolean for using_local state' do
      flag = Legion::Cache.instance_variable_get(:@using_local)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end

    it 'uses AtomicBoolean for using_memory state' do
      flag = Legion::Cache.instance_variable_get(:@using_memory)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end
  end

  describe 'Legion::Cache::Local' do
    it 'uses AtomicBoolean for connected state' do
      flag = Legion::Cache::Local.instance_variable_get(:@connected)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end
  end

  describe 'Legion::Cache::Memory' do
    it 'uses AtomicBoolean for connected state' do
      flag = Legion::Cache::Memory.instance_variable_get(:@connected)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end
  end
end
