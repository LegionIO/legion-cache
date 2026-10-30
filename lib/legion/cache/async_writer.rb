# frozen_string_literal: true

require 'concurrent-ruby'
require 'legion/logging/helper'

module Legion
  module Cache
    class AsyncWriter
      include Legion::Logging::Helper

      DEFAULT_POOL_SIZE = 4
      DEFAULT_QUEUE_SIZE = 1000
      DEFAULT_SHUTDOWN_TIMEOUT = 5

      def initialize(pool_size: nil, queue_size: nil, shutdown_timeout: nil, settings_key: :cache)
        @settings_key = settings_key
        @config_pool_size = pool_size
        @config_queue_size = queue_size
        @config_shutdown_timeout = shutdown_timeout
        @processed = Concurrent::AtomicFixnum.new(0)
        @failed = Concurrent::AtomicFixnum.new(0)
        @mutex = Mutex.new
        @lifecycle_mutex = Mutex.new
        @ready = ConditionVariable.new
        @workers = []
        @queue = []
        @active_keys = {}
        @outstanding = 0
        @capacity = 0
        @running = false
      end

      def start(pool_size: nil, queue_size: nil, **)
        @lifecycle_mutex.synchronize do
          return if running?

          ps = pool_size || @config_pool_size || configured_pool_size
          qs = queue_size || @config_queue_size || configured_queue_size
          raise ArgumentError, 'pool_size must be a positive integer' unless ps.is_a?(Integer) && ps.positive?
          raise ArgumentError, 'queue_size must be a nonnegative integer' unless qs.is_a?(Integer) && qs >= 0

          @mutex.synchronize do
            @capacity = ps + qs
            @running = true
            @workers = Array.new(ps) { Thread.new { work } }
          end
          log.info "Legion::Cache::AsyncWriter started pool_size=#{ps} queue_size=#{qs}"
        end
      end

      def stop(timeout: nil)
        @lifecycle_mutex.synchronize do
          workers = @mutex.synchronize do
            return if @workers.empty?

            @running = false
            @ready.broadcast
            @workers.dup
          end
          to = timeout || @config_shutdown_timeout || configured_shutdown_timeout
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + to
          workers.each do |worker|
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            worker.join(remaining) if remaining.positive?
          end
          unfinished = workers.select(&:alive?)
          unfinished.each(&:kill)
          workers.each(&:join)
          @mutex.synchronize do
            @workers.clear
            @queue.clear
            @active_keys.clear
            @outstanding = 0
            @capacity = 0
          end
          log.warn "Legion::Cache::AsyncWriter force-killed after #{to}s timeout" unless unfinished.empty?
          log.info "Legion::Cache::AsyncWriter stopped processed=#{@processed.value}"
        end
      end

      # Admission includes running and waiting jobs, bounded by pool_size + queue_size.
      # A nil key is independent work; equal non-nil keys execute in submission order.
      def enqueue(key: nil, &block)
        raise ArgumentError, 'a job block is required' unless block

        @mutex.synchronize do
          return false unless @running && @outstanding < @capacity

          key = key.dup.freeze if key.is_a?(String)
          @queue << [key, block]
          @outstanding += 1
          @ready.signal
          true
        end
      end

      def running?
        @mutex.synchronize { @running }
      end

      def pool_size
        @mutex.synchronize { @workers.size }
      end

      def queue_depth
        @mutex.synchronize { @queue.size }
      end

      def processed_count
        @processed.value
      end

      def failed_count
        @failed.value
      end

      private

      def work
        loop do
          job = @mutex.synchronize do
            loop do
              index = @queue.index { |key, _block| key.nil? || !@active_keys.key?(key) }
              if index
                next_job = @queue.delete_at(index)
                @active_keys[next_job.first] = true unless next_job.first.nil?
                break next_job
              end
              return unless @running || !@queue.empty?

              @ready.wait(@mutex)
            end
          end
          perform_job(job)
        end
      end

      def perform_job(job)
        key, block = job
        block.call
        @processed.increment
      rescue StandardError => e
        @failed.increment
        handle_exception(e, level: :warn, handled: true, operation: :async_writer_job)
      ensure
        @mutex.synchronize do
          @active_keys.delete(key) unless key.nil?
          @outstanding -= 1
          @ready.broadcast
        end
      end

      def configured_pool_size
        return DEFAULT_POOL_SIZE unless defined?(Legion::Settings)

        Legion::Settings.dig(@settings_key, :async, :pool_size) || DEFAULT_POOL_SIZE
      rescue StandardError
        DEFAULT_POOL_SIZE
      end

      def configured_queue_size
        return DEFAULT_QUEUE_SIZE unless defined?(Legion::Settings)

        Legion::Settings.dig(@settings_key, :async, :queue_size) || DEFAULT_QUEUE_SIZE
      rescue StandardError
        DEFAULT_QUEUE_SIZE
      end

      def configured_shutdown_timeout
        return DEFAULT_SHUTDOWN_TIMEOUT unless defined?(Legion::Settings)

        Legion::Settings.dig(@settings_key, :async, :shutdown_timeout) || DEFAULT_SHUTDOWN_TIMEOUT
      rescue StandardError
        DEFAULT_SHUTDOWN_TIMEOUT
      end
    end
  end
end
