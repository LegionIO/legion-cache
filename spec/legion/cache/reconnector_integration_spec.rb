# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'reconnector integration' do
  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, false)
    Legion::Cache.instance_variable_set(:@using_local, false)
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache.instance_variable_set(:@reconnector, nil)
    Legion::Cache::Local.reset!
    Legion::Settings[:cache][:enabled] = true
  end

  after do
    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    reconnector&.stop
    Legion::Cache.instance_variable_set(:@reconnector, nil)
    Legion::Settings[:cache][:enabled] = true
  end

  it 'stats reports reconnect_attempts' do
    stats = Legion::Cache.stats
    expect(stats[:reconnect_attempts]).to be_a(Integer)
  end

  it 'setup failure triggers reconnector when enabled' do
    allow(Legion::Cache).to receive(:client).and_raise(RuntimeError, 'refused')
    allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
    allow(Legion::Cache::Local).to receive(:setup)

    Legion::Cache.setup

    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    expect(reconnector).not_to be_nil
    expect(reconnector.running?).to be(true)

    reconnector.stop
  end

  it 'does not start reconnector when disabled' do
    Legion::Settings[:cache][:enabled] = false
    allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
    allow(Legion::Cache::Local).to receive(:setup)

    Legion::Cache.setup

    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    expect(reconnector).to be_nil
    Legion::Settings[:cache][:enabled] = true
  end
end
