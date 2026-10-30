# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'
require 'legion/cache/local'

RSpec.describe Legion::Cache::Local do
  describe 'asynchronous mutations' do
    let(:entered) { Queue.new }
    let(:release) { Queue.new }
    let(:returned) { Queue.new }
    let(:memory) { Legion::Cache::Memory }

    before do
      Legion::Cache.shutdown
      Legion::Settings[:cache][:enabled] = true
      Legion::Settings[:cache_local][:enabled] = true
      described_class.reset!
      memory.reset!
      allow(described_class).to receive(:build_driver).and_return(memory)
      allow(described_class).to receive(:local_settings).and_return(
        Legion::Cache::Settings.local.merge(async: { pool_size: 1, queue_size: 10 })
      )
      described_class.setup
    end

    after do
      release << true
      @caller&.join(2)
      described_class.shutdown
      Legion::Cache.shutdown
      memory.reset!
    end

    {
      set:    [:set_sync, %w[key updated], 'updated'],
      delete: [:delete_sync, ['key'], nil],
      mset:   [:set_sync, [{ 'key' => 'updated' }], 'updated']
    }.each do |operation, (driver_method, arguments, expected)|
      it "returns before a blocked #{operation} finishes and drains it before shutdown" do
        memory.set_sync('key', 'original')
        closed_values = Queue.new
        allow(memory).to receive(:close).and_wrap_original do |method|
          closed_values << memory.get('key')
          method.call
        end
        allow(memory).to receive(driver_method).and_wrap_original do |method, *args, **opts|
          entered << Thread.current
          release.pop
          method.call(*args, **opts)
        end

        @caller = Thread.new { returned << described_class.public_send(operation, *arguments, async: true) }
        worker = entered.pop(timeout: 2)

        expect(returned.pop(timeout: 2)).to be(true)
        expect(worker).not_to eq(@caller)
        expect(described_class.get('key')).to eq('original')

        release << true
        described_class.shutdown

        expect(closed_values.pop(timeout: 2)).to eq(expected)
      end
    end

    it 'keeps explicit synchronous mutations immediately visible through the fallback facade' do
      Legion::Cache.instance_variable_get(:@using_local).make_true
      Legion::Cache.instance_variable_get(:@using_memory).make_false
      Legion::Cache.instance_variable_get(:@connected).make_true

      Legion::Cache.set('key', 'value', async: false)
      expect(described_class.get('key')).to eq('value')

      Legion::Cache.mset({ 'key' => 'updated', 'other' => 'batch' }, async: false)
      expect(described_class.mget('key', 'other')).to eq('key' => 'updated', 'other' => 'batch')

      Legion::Cache.delete('key', async: false)
      expect(described_class.get('key')).to be_nil
    end

    it 'fails closed when the Local backend loses its connection' do
      allow(memory).to receive(:set_sync).and_raise(IOError, 'write failed')

      expect(described_class.set('key', 'value', async: false)).to be(false)
      expect(described_class.connected?).to be(false)
      expect(described_class.set('key', 'value', async: true)).to be(false)
      expect(described_class.cas('key') { raise 'must not run' }).to be(false)
    end

    it 'rebuilds a missing driver on restart and preserves synchronous writes' do
      described_class.shutdown
      expect(described_class.restart).to be(true)
      expect(described_class.set_sync('key', 'restarted')).to be(true)
      expect(described_class.get('key')).to eq('restarted')
    end

    it 'propagates application fetch and cas errors without disconnecting Local' do
      expect { described_class.fetch('key') { raise IOError, 'application' } }.to raise_error(IOError, 'application')
      expect { described_class.cas('key') { raise IOError, 'application' } }.to raise_error(IOError, 'application')
      expect(described_class.connected?).to be(true)
      expect(described_class.get('key')).to be_nil
    end
  end

  describe 'not connected' do
    before { described_class.reset! }

    it 'reports not connected' do
      expect(described_class.connected?).to eq false
    end
  end
end

RSpec.describe 'Legion::Cache::Local integration', :integration do
  before(:all) do
    Legion::Cache::Local.reset!
    Legion::Cache::Local.setup
  end

  after(:all) do
    Legion::Cache::Local.shutdown
  end

  it 'can setup and connect' do
    expect(Legion::Cache::Local.connected?).to eq true
  end

  it 'can set and get' do
    expect(Legion::Cache::Local.set('local_test', 'hello', async: false)).to eq true
    expect(Legion::Cache::Local.get('local_test')).to eq 'hello'
  end

  it 'can set with TTL' do
    expect(Legion::Cache::Local.set('local_ttl', 'expires', ttl: 10, async: false)).to eq true
    expect(Legion::Cache::Local.get('local_ttl')).to eq 'expires'
  end

  it 'can delete' do
    Legion::Cache::Local.set('local_del', 'gone', async: false)
    expect(Legion::Cache::Local.delete('local_del', async: false)).to eq true
    expect(Legion::Cache::Local.get('local_del')).to be_nil
  end

  it 'can flush' do
    Legion::Cache::Local.set('local_flush', 'bye', async: false)
    expect(Legion::Cache::Local.flush).to eq true
  end

  it 'can report size and available' do
    expect(Legion::Cache::Local.size).to eq 5
    expect(Legion::Cache::Local.available).to be_a(Integer)
  end

  it 'can report pool_size and timeout' do
    expect(Legion::Cache::Local.pool_size).to eq 5
    expect(Legion::Cache::Local.timeout).to eq 3
  end

  it 'can shutdown and reconnect' do
    Legion::Cache::Local.shutdown
    expect(Legion::Cache::Local.connected?).to eq false
    Legion::Cache::Local.setup
    expect(Legion::Cache::Local.connected?).to eq true
  end

  it 'can restart with new values' do
    Legion::Cache::Local.restart(pool_size: 2, timeout: 1)
    expect(Legion::Cache::Local.connected?).to eq true
    expect(Legion::Cache::Local.set('restart_test', 'works', async: false)).to eq true
    expect(Legion::Cache::Local.get('restart_test')).to eq 'works'
  end

  it 'uses separate namespace from shared cache' do
    Legion::Cache::Local.set('ns_test', 'local_value', async: false)
    Legion::Cache.setup
    Legion::Cache.set('ns_test', 'shared_value', async: false)
    expect(Legion::Cache::Local.get('ns_test')).to eq 'local_value'
    expect(Legion::Cache.get('ns_test')).to eq 'shared_value'
    Legion::Cache.shutdown
  end
end
