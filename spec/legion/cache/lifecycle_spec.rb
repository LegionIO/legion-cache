# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'full cache lifecycle' do
  let(:local_store) { {} }
  let(:shared_available) { Concurrent::AtomicBoolean.new(false) }

  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache::Local.reset!

    Legion::Settings[:cache][:enabled] = true

    # Stub Local
    allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
    allow(Legion::Cache::Local).to receive(:enabled?).and_return(true)
    allow(Legion::Cache::Local).to receive(:setup)
    allow(Legion::Cache::Local).to receive(:shutdown)
    allow(Legion::Cache::Local).to receive(:get) { |key| local_store[key] }
    allow(Legion::Cache::Local).to receive(:set) do |key, value, **|
      local_store[key] = value
      true
    end

    # Stub shared to fail initially
    allow(Legion::Cache).to receive(:client).and_invoke(
      lambda { |**|
        raise 'connection refused' if shared_available.false?

        nil
      }
    )
  end

  after do
    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    reconnector&.stop
    Legion::Settings[:cache][:enabled] = true
  end

  it 'fails back to local, then recovers when shared comes back' do
    # Phase 1: shared fails, falls back to local
    Legion::Cache.setup
    expect(Legion::Cache.using_local?).to be(true)

    # Phase 2: operations work via local
    Legion::Cache.set('lifecycle', 'local_value', async: false)
    expect(Legion::Cache.get('lifecycle')).to eq('local_value')
    expect(local_store['lifecycle']).to eq('local_value')

    # Phase 3: shared comes back
    shared_available.make_true

    # Phase 4: verify reconnector was started
    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    expect(reconnector).not_to be_nil

    # Cleanup
    reconnector.stop
  end

  it 'returns nil everywhere when both shared and local are down' do
    allow(Legion::Cache::Local).to receive(:connected?).and_return(false)

    Legion::Cache.setup
    expect(Legion::Cache.get('anything')).to be_nil
  end
end
