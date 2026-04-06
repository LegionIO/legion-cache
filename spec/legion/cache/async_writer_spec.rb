# frozen_string_literal: true

require 'spec_helper'
require 'concurrent-ruby'
require 'legion/cache/async_writer'

RSpec.describe Legion::Cache::AsyncWriter do
  subject(:writer) { described_class.new }

  after { writer.stop(timeout: 2) if writer.running? }

  describe '#start' do
    it 'starts the thread pool' do
      writer.start
      expect(writer.running?).to be(true)
    end

    it 'is idempotent' do
      writer.start
      writer.start
      expect(writer.running?).to be(true)
    end
  end

  describe '#stop' do
    it 'drains pending work within timeout' do
      writer.start
      completed = Concurrent::AtomicBoolean.new(false)
      writer.enqueue { completed.make_true }
      writer.stop(timeout: 5)
      expect(completed.value).to be(true)
      expect(writer.running?).to be(false)
    end
  end

  describe '#enqueue' do
    it 'executes the block asynchronously' do
      writer.start
      result = Concurrent::AtomicReference.new(nil)
      writer.enqueue { result.set('done') }
      sleep 0.1
      expect(result.get).to eq('done')
    end

    it 'increments processed_count' do
      writer.start
      3.times { writer.enqueue { nil } }
      sleep 0.2
      expect(writer.processed_count).to eq(3)
    end

    it 'falls back to synchronous when pool is not running' do
      result = nil
      writer.enqueue { result = 'sync_fallback' }
      expect(result).to eq('sync_fallback')
    end
  end

  describe 'thread safety' do
    it 'handles concurrent stop and enqueue without error' do
      writer.start
      errors = Concurrent::AtomicFixnum.new(0)
      threads = 10.times.map do
        Thread.new do
          50.times { writer.enqueue { nil } }
        rescue StandardError
          errors.increment
        end
      end
      sleep 0.05
      writer.stop(timeout: 2)
      threads.each(&:join)
      expect(errors.value).to eq(0)
    end
  end

  describe '#failed_count' do
    it 'tracks failed jobs separately from processed' do
      writer.start
      writer.enqueue { raise 'boom' }
      sleep 0.2
      expect(writer.failed_count).to eq(1)
      expect(writer.processed_count).to eq(0)
    end
  end

  describe '#pool_size' do
    it 'returns configured pool size' do
      writer.start(pool_size: 2)
      expect(writer.pool_size).to eq(2)
    end
  end

  describe '#queue_depth' do
    it 'returns 0 when idle' do
      writer.start
      sleep 0.05
      expect(writer.queue_depth).to eq(0)
    end
  end
end
