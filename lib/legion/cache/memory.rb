# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Cache
    module Memory
      extend self
      extend Legion::Logging::Helper

      @store = {}
      @expiry = {}
      @mutex = Mutex.new
      @connected = false

      def setup(**)
        @connected = true
        log.info 'Legion::Cache::Memory connected'
        @connected
      end

      def client(**) = self

      def connected?
        @connected
      end

      def get(key)
        @mutex.synchronize do
          expire_if_needed(key)
          result = @store[key]
          log.debug { "[cache:memory] GET #{key} hit=#{!result.nil?}" }
          result
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_get, key: key)
        nil
      end

      def set(key, value, ttl: nil, **)
        set_sync(key, value, ttl: ttl)
      end

      def set_sync(key, value, ttl: nil, **)
        effective_ttl = ttl || default_ttl
        @mutex.synchronize do
          @store[key] = value
          if effective_ttl&.positive?
            @expiry[key] = Time.now + effective_ttl
          else
            @expiry.delete(key)
          end
          log.debug { "[cache:memory] SET #{key} ttl=#{effective_ttl.inspect}" }
          value
        end
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memory_set_sync, key: key)
        raise
      end

      def fetch(key, ttl: nil)
        val = get(key)
        return val unless val.nil?

        log.debug { "[cache:memory] FETCH #{key} miss=true" }
        val = yield if block_given?
        set(key, val, ttl: ttl)
        val
      end

      def delete(key, **)
        delete_sync(key)
      end

      def delete_sync(key)
        @mutex.synchronize do
          removed = @store.delete(key)
          @expiry.delete(key)
          log.debug { "[cache:memory] DELETE #{key} success=#{!removed.nil?}" }
          removed
        end
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memory_delete_sync, key: key)
        raise
      end

      def flush
        result = @mutex.synchronize do
          @store.clear
          @expiry.clear
        end
        log.info 'Legion::Cache::Memory flushed'
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_flush)
        nil
      end

      def close = nil

      def shutdown
        flush
        @connected = false
        log.info 'Legion::Cache::Memory shut down'
        @connected
      end

      def reset!
        result = @mutex.synchronize do
          @store.clear
          @expiry.clear
          @connected = false
        end
        log.info 'Legion::Cache::Memory state reset'
        result
      end

      def size = 1
      def available = 1

      def default_ttl
        3600
      end

      private

      def expire_if_needed(key)
        return unless @expiry.key?(key) && Time.now > @expiry[key]

        @store.delete(key)
        @expiry.delete(key)
        log.debug { "[cache:memory] EXPIRE #{key}" }
      end
    end
  end
end
