# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'facade asynchronous admission' do
  before do
    Legion::Cache.shutdown
    @mode = ENV['LEGION_MODE']
    @async_settings = Legion::Settings[:cache][:async]
    ENV['LEGION_MODE'] = 'lite'
    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:async] = { pool_size: 1, queue_size: 1, shutdown_timeout: 2 }
    Legion::Cache.setup
    @entered = Queue.new
    @release = Queue.new
  end

  after do
    @release << true
    Legion::Cache.shutdown
    Legion::Settings[:cache][:async] = @async_settings
    @mode ? ENV['LEGION_MODE'] = @mode : ENV.delete('LEGION_MODE')
  end

  it 'reports full queues without executing rejected writes in the caller' do
    allow(Legion::Cache::Memory).to receive(:set_sync).and_wrap_original do |method, key, value, **options|
      if key == 'blocked'
        @entered << true
        @release.pop
      end
      method.call(key, value, **options)
    end
    expect(Legion::Cache.set('blocked', 'first')).to be(true)
    @entered.pop(timeout: 2)
    expect(Legion::Cache.set('queued', 'second')).to be(true)
    expect(Legion::Cache.mset({ 'rejected' => 'third' })).to be(false)
    expect(Legion::Cache.delete('queued')).to be(false)
    expect(Legion::Cache.get('rejected')).to be_nil
    @release << true
    Legion::Cache.instance_variable_get(:@async_writer).stop
    expect(Legion::Cache.get('queued')).to eq('second')
    expect(Legion::Cache.get('rejected')).to be_nil
  end

  it 'rejects stopped-writer admission while explicit synchronous writes still work' do
    Legion::Cache.instance_variable_get(:@async_writer).stop
    expect(Legion::Cache.set('key', 'rejected')).to be(false)
    expect(Legion::Cache.get('key')).to be_nil
    expect(Legion::Cache.set('key', 'visible', async: false)).to be(true)
    expect(Legion::Cache.get('key')).to eq('visible')
  end
end
