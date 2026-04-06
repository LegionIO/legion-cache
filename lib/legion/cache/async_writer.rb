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

      def initialize(pool_size: nil, queue_size: nil, shutdown_timeout: nil)
        @config_pool_size = pool_size
        @config_queue_size = queue_size
        @config_shutdown_timeout = shutdown_timeout
        @processed = Concurrent::AtomicFixnum.new(0)
        @executor = nil
        @mutex = Mutex.new
      end

      def start(pool_size: nil, queue_size: nil, **)
        @mutex.synchronize do
          return if running?

          ps = pool_size || @config_pool_size || configured_pool_size
          qs = queue_size || @config_queue_size || configured_queue_size

          @executor = Concurrent::ThreadPoolExecutor.new(
            min_threads:     1,
            max_threads:     ps,
            max_queue:       qs,
            fallback_policy: :caller_runs
          )
          log.info "Legion::Cache::AsyncWriter started pool_size=#{ps} queue_size=#{qs}"
        end
      end

      def stop(timeout: nil)
        @mutex.synchronize do
          return unless @executor

          to = timeout || @config_shutdown_timeout || configured_shutdown_timeout
          @executor.shutdown
          unless @executor.wait_for_termination(to)
            @executor.kill
            log.warn "Legion::Cache::AsyncWriter force-killed after #{to}s timeout"
          end
          log.info "Legion::Cache::AsyncWriter stopped processed=#{@processed.value}"
          @executor = nil
        end
      end

      def enqueue(&block)
        if running?
          @executor.post do
            block.call
            @processed.increment
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: :async_writer_job)
            @processed.increment
          end
        else
          begin
            block.call
            @processed.increment
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: :async_writer_sync_fallback)
            @processed.increment
          end
        end
      end

      def running?
        @executor&.running? == true
      end

      def pool_size
        @executor&.max_length || 0
      end

      def queue_depth
        @executor&.queue_length || 0
      end

      def processed_count
        @processed.value
      end

      private

      def configured_pool_size
        return DEFAULT_POOL_SIZE unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :async, :pool_size) || DEFAULT_POOL_SIZE
      rescue StandardError
        DEFAULT_POOL_SIZE
      end

      def configured_queue_size
        return DEFAULT_QUEUE_SIZE unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :async, :queue_size) || DEFAULT_QUEUE_SIZE
      rescue StandardError
        DEFAULT_QUEUE_SIZE
      end

      def configured_shutdown_timeout
        return DEFAULT_SHUTDOWN_TIMEOUT unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :async, :shutdown_timeout) || DEFAULT_SHUTDOWN_TIMEOUT
      rescue StandardError
        DEFAULT_SHUTDOWN_TIMEOUT
      end
    end
  end
end
