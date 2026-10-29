# frozen_string_literal: true

require 'spec_helper'
require 'concurrent-ruby'
require 'timeout'
require 'legion/cache/async_writer'

RSpec.describe Legion::Cache::AsyncWriter do
  subject(:writer) { described_class.new }

  after { writer.stop(timeout: 2) }

  describe '#start' do
    it 'starts the thread pool idempotently' do
      writer.start(pool_size: 2)
      writer.start(pool_size: 1)
      expect(writer.running?).to be(true)
      expect(writer.pool_size).to eq(2)
    end
  end

  describe '#stop' do
    it 'drains pending work within timeout' do
      writer.start
      completed = []
      3.times { |index| writer.enqueue(key: :entry) { completed << index } }
      writer.stop(timeout: 2)
      expect(completed).to eq([0, 1, 2])
      expect(writer.processed_count).to eq(3)
      expect(writer.running?).to be(false)
      expect(writer.pool_size).to eq(0)
      expect(writer.queue_depth).to eq(0)
    end

    it 'rejects admission promptly while draining accepted jobs' do
      writer.start(pool_size: 1)
      started = Queue.new
      release = Queue.new
      completed = []
      writer.enqueue(key: :entry) do
        started << true
        release.pop
        completed << :first
      end
      Timeout.timeout(2) { started.pop }
      writer.enqueue(key: :entry) { completed << :second }
      stopping = Thread.new { writer.stop(timeout: 2) }
      Timeout.timeout(2) { Thread.pass while writer.running? }
      expect(Timeout.timeout(1) { writer.enqueue { completed << :rejected } }).to be(false)
      release << true
      expect(stopping.join(2)).to eq(stopping)
      expect(completed).to eq(%i[first second])
      expect(writer.processed_count).to eq(2)
    ensure
      release << true if release
      stopping&.join(2)
    end

    it 'releases queued work and key ownership after forced shutdown and can restart' do
      writer.start(pool_size: 2)
      started = Queue.new
      release = Queue.new
      completed = []
      writer.enqueue(key: :entry) do
        started << true
        release.pop
        completed << :blocked
      end
      Timeout.timeout(2) { started.pop }
      writer.enqueue(key: :entry) { completed << :cancelled }
      writer.stop(timeout: 0)
      expect(writer.queue_depth).to eq(0)
      expect(writer.pool_size).to eq(0)
      expect(writer.running?).to be(false)
      expect(writer.enqueue { completed << :rejected }).to be(false)
      writer.start(pool_size: 1, queue_size: 0)
      expect(writer.enqueue(key: :entry) { completed << :restarted }).to be(true)
      writer.stop(timeout: 2)
      expect(completed).to eq([:restarted])
      expect(writer.processed_count).to eq(1)
      expect(writer.failed_count).to eq(0)
    ensure
      release << true if release
    end
  end

  describe '#enqueue' do
    it 'executes accepted work on a worker, not the caller' do
      writer.start
      worker_thread = Queue.new
      expect(writer.enqueue { worker_thread << Thread.current }).to be(true)
      expect(Timeout.timeout(2) { worker_thread.pop }).not_to eq(Thread.current)
      writer.stop(timeout: 2)
      expect(writer.processed_count).to eq(1)
    end

    it 'rejects work when the pool is not running without executing it' do
      executed = false
      expect(writer.enqueue { executed = true }).to be(false)
      expect(executed).to be(false)
    end

    it 'rejects saturated work promptly without executing it on the caller' do
      writer.start(pool_size: 1, queue_size: 1)
      started = Queue.new
      release = Queue.new
      executed = []
      expect(writer.enqueue do
        started << true
        release.pop
        executed << :first
      end).to be(true)
      Timeout.timeout(2) { started.pop }
      expect(writer.enqueue { executed << :second }).to be(true)
      accepted = Timeout.timeout(2) do
        writer.enqueue do
          executed << :rejected
          release.pop
        end
      end
      expect(accepted).to be(false)
      release << true
      writer.stop(timeout: 2)
      expect(executed).to eq(%i[first second])
      expect(writer.processed_count).to eq(2)
    ensure
      release << true if release
    end

    it 'preserves per-key set and delete order without blocking other keys' do
      writer.start(pool_size: 2, queue_size: 4)
      started = Queue.new
      release = Queue.new
      other_finished = Queue.new
      cache = Concurrent::Map.new
      observed = Queue.new
      writer.enqueue(key: 'entry') do
        started << true
        release.pop
        cache[:entry] = :first
      end
      Timeout.timeout(2) { started.pop }
      expect(writer.enqueue(key: 'entry') { observed << cache.delete(:entry) }).to be(true)
      expect(writer.enqueue(key: 'entry') { cache[:entry] = :last }).to be(true)
      expect(writer.enqueue(key: 'other') do
        cache[:other] = :independent
        other_finished << true
      end).to be(true)
      Timeout.timeout(2) { other_finished.pop }
      expect(cache[:other]).to eq(:independent)
      expect(cache[:entry]).to be_nil
      expect(observed.empty?).to be(true)
      release << true
      writer.stop(timeout: 2)
      expect(observed.pop).to eq(:first)
      expect(cache[:entry]).to eq(:last)
      expect(writer.processed_count).to eq(4)
    ensure
      release << true if release
    end

    it 'bounds total admitted work even when all pending jobs share an active key' do
      writer.start(pool_size: 2, queue_size: 1)
      started = Queue.new
      release = Queue.new
      executed = []
      expect(writer.enqueue(key: :entry) do
        started << true
        release.pop
        executed << :first
      end).to be(true)
      Timeout.timeout(2) { started.pop }
      expect(writer.enqueue(key: :entry) { executed << :second }).to be(true)
      expect(writer.enqueue(key: :entry) { executed << :third }).to be(true)
      expect(writer.enqueue(key: :entry) { executed << :rejected }).to be(false)
      expect(writer.queue_depth).to eq(2)
      release << true
      writer.stop(timeout: 2)
      expect(executed).to eq(%i[first second third])
      expect(writer.processed_count).to eq(3)
    ensure
      release << true if release
    end

    it 'treats unkeyed jobs as independent work' do
      writer.start(pool_size: 2)
      started = Queue.new
      release = Queue.new
      other_finished = Queue.new
      writer.enqueue do
        started << true
        release.pop
      end
      Timeout.timeout(2) { started.pop }
      writer.enqueue { other_finished << true }
      expect(Timeout.timeout(2) { other_finished.pop }).to be(true)
    ensure
      release << true if release
    end
  end

  describe 'thread safety' do
    it 'executes exactly the accepted submissions during concurrent stop and enqueue' do
      writer.start(pool_size: 2, queue_size: 10)
      accepted = Concurrent::AtomicFixnum.new(0)
      rejected = Concurrent::AtomicFixnum.new(0)
      threads = 10.times.map do
        Thread.new do
          50.times do
            if writer.enqueue { nil }
              accepted.increment
            else
              rejected.increment
            end
          end
        end
      end
      writer.stop(timeout: 2)
      threads.each(&:value)
      expect(accepted.value + rejected.value).to eq(500)
      expect(writer.processed_count).to eq(accepted.value)
      expect(writer.failed_count).to eq(0)
    end
  end

  describe '#failed_count' do
    it 'releases a failed key so later writes execute and counts only executed failures' do
      writer.start(pool_size: 2)
      completed = []
      writer.enqueue(key: :entry) { raise 'boom' }
      writer.enqueue(key: :entry) { completed << :recovered }
      writer.stop(timeout: 2)
      expect(completed).to eq([:recovered])
      expect(writer.failed_count).to eq(1)
      expect(writer.processed_count).to eq(1)
    end
  end
end
