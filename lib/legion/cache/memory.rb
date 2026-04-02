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
      end

      def set(key, value, ttl = nil)
        @mutex.synchronize do
          @store[key] = value
          if ttl&.positive?
            @expiry[key] = Time.now + ttl
          else
            @expiry.delete(key)
          end
          log.debug { "[cache:memory] SET #{key} ttl=#{ttl.inspect}" }
          value
        end
      end

      def fetch(key, ttl = nil)
        val = get(key)
        return val unless val.nil?

        log.debug { "[cache:memory] FETCH #{key} miss=true" }
        val = yield if block_given?
        set(key, val, ttl)
        val
      end

      def delete(key)
        @mutex.synchronize do
          removed = @store.delete(key)
          @expiry.delete(key)
          log.debug { "[cache:memory] DELETE #{key} success=#{!removed.nil?}" }
          removed
        end
      end

      def flush(_delay = 0)
        result = @mutex.synchronize do
          @store.clear
          @expiry.clear
        end
        log.info 'Legion::Cache::Memory flushed'
        result
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
