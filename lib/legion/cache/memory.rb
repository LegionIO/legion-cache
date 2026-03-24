# frozen_string_literal: true

module Legion
  module Cache
    module Memory
      extend self

      @store = {}
      @expiry = {}
      @mutex = Mutex.new
      @connected = false

      def setup(**)
        @connected = true
      end

      def client(**) = self

      def connected?
        @connected
      end

      def get(key)
        @mutex.synchronize do
          expire_if_needed(key)
          @store[key]
        end
      end

      def set(key, value, ttl = nil)
        @mutex.synchronize do
          @store[key] = value
          @expiry[key] = Time.now + ttl if ttl&.positive?
          value
        end
      end

      def fetch(key, ttl = nil)
        val = get(key)
        return val unless val.nil?

        val = yield if block_given?
        set(key, val, ttl)
        val
      end

      def delete(key)
        @mutex.synchronize do
          @store.delete(key)
          @expiry.delete(key)
        end
      end

      def flush(_delay = 0)
        @mutex.synchronize do
          @store.clear
          @expiry.clear
        end
      end

      def close = nil

      def shutdown
        flush
        @connected = false
      end

      def reset!
        @mutex.synchronize do
          @store.clear
          @expiry.clear
          @connected = false
        end
      end

      def size = 1
      def available = 1

      private

      def expire_if_needed(key)
        return unless @expiry.key?(key) && Time.now > @expiry[key]

        @store.delete(key)
        @expiry.delete(key)
      end
    end
  end
end
