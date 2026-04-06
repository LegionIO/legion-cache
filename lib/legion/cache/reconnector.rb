# frozen_string_literal: true

require 'concurrent-ruby'
require 'legion/logging/helper'

module Legion
  module Cache
    class Reconnector
      include Legion::Logging::Helper

      DEFAULT_INITIAL_DELAY = 1
      DEFAULT_MAX_DELAY = 60

      def initialize(tier:, connect_block:, enabled_block:)
        @tier = tier
        @connect_block = connect_block
        @enabled_block = enabled_block
        @attempts = Concurrent::AtomicFixnum.new(0)
        @thread = nil
        @mutex = Mutex.new
        @stop_signal = false
        @next_retry_at = nil
      end

      def start
        @mutex.synchronize do
          return if running?

          @stop_signal = false
          @thread = Thread.new { reconnect_loop }
          log.info "Legion::Cache::Reconnector[#{@tier}] started"
        end
      end

      def stop
        @mutex.synchronize do
          @stop_signal = true
          @thread&.join(5)
          @thread = nil
          log.info "Legion::Cache::Reconnector[#{@tier}] stopped"
        end
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

        until @stop_signal
          unless @enabled_block.call
            sleep 1
            next
          end

          begin
            @next_retry_at = Time.now + delay
            sleep delay
            return if @stop_signal

            @connect_block.call
            @attempts.value = 0
            @next_retry_at = nil
            log.info "Legion::Cache::Reconnector[#{@tier}] reconnected"
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
      end

      def configured_initial_delay
        return DEFAULT_INITIAL_DELAY unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :reconnect, :initial_delay) || DEFAULT_INITIAL_DELAY
      rescue StandardError
        DEFAULT_INITIAL_DELAY
      end

      def configured_max_delay
        return DEFAULT_MAX_DELAY unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :reconnect, :max_delay) || DEFAULT_MAX_DELAY
      rescue StandardError
        DEFAULT_MAX_DELAY
      end
    end
  end
end
