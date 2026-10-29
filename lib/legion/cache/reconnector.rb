# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'

module Legion
  module Cache
    class Reconnector
      include Legion::Logging::Helper

      DEFAULT_INITIAL_DELAY = 1
      DEFAULT_MAX_DELAY = 60
      STOP_TIMEOUT = 1

      def initialize(tier:, connect_block:, enabled_block:, settings_key: :cache)
        @tier = tier
        @connect_block = connect_block
        @enabled_block = enabled_block
        @settings_key = settings_key
        @attempts = Concurrent::AtomicFixnum.new(0)
        @thread = nil
        @mutex = Mutex.new
        @wake = ConditionVariable.new
        @stopping = false
        @stop_signal = Concurrent::AtomicBoolean.new(false)
        @next_retry_at = nil
      end

      def start
        return unless configured_enabled?

        @mutex.synchronize do
          return if @stopping || running?

          @stop_signal.make_false
          @thread = Thread.new { reconnect_loop }
          log.info "Legion::Cache::Reconnector[#{@tier}] started"
        end
      end

      def stop
        thread_to_join = @mutex.synchronize do
          @stopping = true unless @thread == Thread.current
          @stop_signal.make_true
          @wake.broadcast
          @thread
        end
        Thread.exit if thread_to_join == Thread.current

        if thread_to_join && !thread_to_join.join(STOP_TIMEOUT)
          thread_to_join.kill
          unless thread_to_join.join(STOP_TIMEOUT)
            raise ThreadError, "Legion::Cache::Reconnector[#{@tier}] could not stop its connection callback"
          end
        end

        @mutex.synchronize do
          if @thread == thread_to_join
            @thread = nil
            @stopping = false
          end
        end
        log.info "Legion::Cache::Reconnector[#{@tier}] stopped"
      end

      def running?
        @thread&.alive? == true
      end

      def attempts
        @attempts.value
      end

      attr_reader :next_retry_at

      private

      def reconnect_loop
        delay = configured_initial_delay

        until @stop_signal.true?
          unless configured_enabled? && @enabled_block.call
            wait_for_retry(1)
            next
          end

          begin
            @next_retry_at = Time.now + delay
            return unless wait_for_retry(delay)
            next unless configured_enabled? && @enabled_block.call

            @connect_block.call
            count = @attempts.value
            @attempts.value = 0
            @next_retry_at = nil
            log.info "Legion::Cache::Reconnector[#{@tier}] reconnected after #{count} attempts"
            return
          rescue StandardError => e
            @attempts.increment
            handle_exception(e, level: :warn, handled: true,
                             operation: :"reconnector_#{@tier}",
                             attempt: @attempts.value, next_delay: delay)
            delay = [delay * 2, configured_max_delay].min
          end
        end
      rescue StandardError => e
        handle_exception(e, level: :error, handled: true, operation: :"reconnector_#{@tier}_loop")
      ensure
        @next_retry_at = nil
      end

      def wait_for_retry(delay)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + delay
        @mutex.synchronize do
          until @stop_signal.true?
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            return true unless remaining.positive?

            @wake.wait(@mutex, remaining)
          end
        end
        false
      end

      def configured_enabled?
        return true unless defined?(Legion::Settings)

        Legion::Settings.dig(@settings_key, :enabled) != false &&
          Legion::Settings.dig(@settings_key, :reconnect, :enabled) != false
      end

      def configured_initial_delay
        return DEFAULT_INITIAL_DELAY unless defined?(Legion::Settings)

        Legion::Settings.dig(@settings_key, :reconnect, :initial_delay) || DEFAULT_INITIAL_DELAY
      rescue StandardError
        DEFAULT_INITIAL_DELAY
      end

      def configured_max_delay
        return DEFAULT_MAX_DELAY unless defined?(Legion::Settings)

        Legion::Settings.dig(@settings_key, :reconnect, :max_delay) || DEFAULT_MAX_DELAY
      rescue StandardError
        DEFAULT_MAX_DELAY
      end
    end
  end
end
