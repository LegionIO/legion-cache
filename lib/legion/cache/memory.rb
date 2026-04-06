# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'

module Legion
  module Cache
    module Memory
      extend self
      extend Legion::Logging::Helper

      @store = {}
      @expiry = {}
      @mutex = Mutex.new
      @connected = Concurrent::AtomicBoolean.new(false)

      def setup(**)
        @connected.make_true
        log.info 'Legion::Cache::Memory connected'
        true
      rescue StandardError => e
        @connected.make_false
        handle_exception(e, level: :warn, handled: true, operation: :memory_setup)
        false
      end

      def client(**) = self

      def connected?
        @connected.true?
      end

      def restart(**)
        shutdown
        setup
      rescue StandardError => e
        @connected.make_false
        handle_exception(e, level: :warn, handled: true, operation: :memory_restart)
        false
      end

      def get(key)
        @mutex.synchronize do
          expire_if_needed(key)
          result = @store[key]
          log.debug { "[cache:memory] GET #{key} hit=#{!result.nil?}" }
          result
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_get)
        nil
      end

      def set(key, value, ttl: nil, async: true, phi: false) # rubocop:disable Lint/UnusedMethodArgument
        set_sync(key, value, ttl: ttl, phi: phi)
      end

      def set_sync(key, value, ttl: nil, phi: false)
        ttl = enforce_phi_ttl(ttl, phi: phi) if phi
        @mutex.synchronize do
          @store[key] = value
          if ttl&.positive?
            @expiry[key] = Time.now + ttl
          else
            @expiry.delete(key)
          end
          log.debug { "[cache:memory] SET #{key} ttl=#{ttl.inspect}" }
          true
        end
      end

      def fetch(key, ttl: nil, &block)
        val = get(key)
        return val unless val.nil?

        log.debug { "[cache:memory] FETCH #{key} miss=true" }
        val = block&.call
        set(key, val, ttl: ttl)
        val
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_fetch)
        nil
      end

      def delete(key, async: true) # rubocop:disable Lint/UnusedMethodArgument
        delete_sync(key)
      end

      def delete_sync(key)
        @mutex.synchronize do
          removed = @store.delete(key)
          @expiry.delete(key)
          log.debug { "[cache:memory] DELETE #{key} success=#{!removed.nil?}" }
          !removed.nil?
        end
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        @mutex.synchronize do
          keys.each { |k| expire_if_needed(k) }
          keys.to_h { |k| [k, @store[k]] }
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_mget)
        {}
      end

      def mset(hash, ttl: nil, async: true)
        return true if hash.empty?

        hash.each { |k, v| set(k, v, ttl: ttl, async: async) }
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_mset)
        true
      end

      def mset_sync(hash, ttl: nil, phi: false)
        return true if hash.empty?

        @mutex.synchronize do
          hash.each do |key, value|
            effective_ttl = phi ? enforce_phi_ttl(ttl, phi: true) : ttl
            @store[key] = value
            if effective_ttl&.positive?
              @expiry[key] = Time.now + effective_ttl
            else
              @expiry.delete(key)
            end
          end
          true
        end
      end

      def flush
        @mutex.synchronize do
          @store.clear
          @expiry.clear
        end
        log.info 'Legion::Cache::Memory flushed'
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_flush)
        false
      end

      def close = nil

      def shutdown
        flush
        @connected.make_false
        log.info 'Legion::Cache::Memory shut down'
        false
      rescue StandardError => e
        @connected.make_false
        handle_exception(e, level: :warn, handled: true, operation: :memory_shutdown)
        false
      end

      def reset!
        @mutex.synchronize do
          @connected.make_false
          @store.clear
          @expiry.clear
        end
        log.info 'Legion::Cache::Memory state reset'
        false
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

      def enforce_phi_ttl(ttl, phi: false)
        return ttl unless phi

        max = if defined?(Legion::Settings)
                Legion::Settings.dig(:cache, :compliance, :phi_max_ttl) || 3600
              else
                3600
              end
        result = ttl.nil? ? max : [ttl, max].min
        [result, 1].max
      end
    end
  end
end
