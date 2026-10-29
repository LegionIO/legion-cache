# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'

module Legion
  module Cache
    # Shared bounded storage for Memory and Cacheable's process-local fallback.
    # Cleanup exists only while expiring entries exist; clear/close joins it.
    class ExpiringStore
      DEFAULT_MAX_ENTRIES = 10_000

      def initialize(max_entries: DEFAULT_MAX_ENTRIES)
        @entries = {}
        @expiry = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        self.max_entries = max_entries
      end

      def max_entries=(limit)
        raise ArgumentError, 'max_entries must be a positive integer' unless limit.is_a?(Integer) && limit.positive?

        @mutex.synchronize do
          @max_entries = limit
          evict_oldest while @entries.size > limit
        end
      end

      def get(key)
        @mutex.synchronize do
          expire_key(key)
          @entries[key]
        end
      end

      def set(key, value, ttl: nil, unless_exist: false)
        deadline = expiry_deadline(ttl)
        @mutex.synchronize do
          expire_key(key)
          return false if unless_exist && @entries.key?(key)

          write_entry(key, value, deadline)
        end
        true
      end

      def mget(keys)
        @mutex.synchronize do
          keys.to_h do |key|
            expire_key(key)
            [key, @entries[key]]
          end
        end
      end

      def mset(values, ttl: nil)
        deadline = expiry_deadline(ttl)
        @mutex.synchronize { values.each { |key, value| write_entry(key, value, deadline) } }
        true
      end

      def delete(key)
        @mutex.synchronize do
          expire_key(key)
          present = @entries.key?(key)
          @entries.delete(key)
          @expiry.delete(key)
          @condition.signal
          present
        end
      end

      def clear
        worker = @mutex.synchronize do
          @entries.clear
          @expiry.clear
          @next_expiry = nil
          thread = @cleanup_thread
          @cleanup_thread = nil
          @condition.broadcast
          thread
        end
        worker&.join
        true
      end

      def close
        clear
      end

      # Does not opportunistically expire entries: cleanup reclaims inactive keys.
      def size
        @mutex.synchronize { @entries.size }
      end

      private

      def expiry_deadline(ttl)
        return if ttl.nil? || ttl == 0
        raise ArgumentError, 'ttl must be a finite nonnegative number' unless ttl.is_a?(Numeric) && ttl.real? && ttl.finite? && ttl.positive?

        monotonic_now + ttl
      end

      def monotonic_now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def expire_key(key)
        return unless @expiry.key?(key) && @expiry[key] <= monotonic_now

        @entries.delete(key)
        @expiry.delete(key)
        @condition.signal
      end

      def write_entry(key, value, deadline)
        if !@entries.key?(key) && @entries.size >= @max_entries
          purge_expired if @next_expiry && @next_expiry <= monotonic_now
          evict_oldest if @entries.size >= @max_entries
        end
        @entries[key] = value
        if deadline
          @expiry[key] = deadline
          @next_expiry = deadline if @next_expiry.nil? || deadline < @next_expiry
          @cleanup_thread ||= Thread.new { cleanup_loop }
        else
          @expiry.delete(key)
        end
        @condition.signal
      end

      def evict_oldest
        key, = @entries.shift
        @expiry.delete(key)
        @condition.signal
      end

      def purge_expired
        now = monotonic_now
        @expiry.delete_if do |key, deadline|
          next false if deadline > now

          @entries.delete(key)
          true
        end
        @next_expiry = @expiry.each_value.min
      end

      def cleanup_loop
        @mutex.synchronize do
          while @cleanup_thread.equal?(Thread.current)
            purge_expired if @next_expiry && @next_expiry <= monotonic_now
            break if @expiry.empty?

            delay = @next_expiry - monotonic_now
            @condition.wait(@mutex, delay) if delay.positive?
          end
          @cleanup_thread = nil if @cleanup_thread.equal?(Thread.current)
        end
      end
    end

    module Memory
      extend self
      extend Legion::Logging::Helper

      @store = ExpiringStore.new
      @connected = Concurrent::AtomicBoolean.new(false)

      def setup(max_entries: nil, **)
        @store.max_entries = max_entries unless max_entries.nil?
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

      def restart(**options)
        shutdown
        setup(**options)
      rescue StandardError => e
        @connected.make_false
        handle_exception(e, level: :warn, handled: true, operation: :memory_restart)
        false
      end

      def get(key)
        result = @store.get(key)
        log.debug { "[cache:memory] GET #{key} hit=#{!result.nil?}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_get)
        nil
      end

      def set(key, value, ttl: nil, async: true, phi: false) # rubocop:disable Lint/UnusedMethodArgument
        set_sync(key, value, ttl: ttl, phi: phi)
      end

      def set_nx(key, value, ttl: nil)
        result = @store.set(key, value, ttl: ttl, unless_exist: true)
        log.debug { "[cache:memory] SET_NX #{key} ttl=#{ttl.inspect} result=#{result}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_set_nx)
        false
      end

      def set_sync(key, value, ttl: nil, phi: false)
        ttl = enforce_phi_ttl(ttl, phi: phi) if phi
        @store.set(key, value, ttl: ttl)
        log.debug { "[cache:memory] SET #{key} ttl=#{ttl.inspect}" }
        true
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
        removed = @store.delete(key)
        log.debug { "[cache:memory] DELETE #{key} success=#{removed}" }
        removed
      end

      def mget(*keys)
        @store.mget(keys.flatten)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_mget)
        {}
      end

      def mset(hash, ttl: nil, async: true) # rubocop:disable Lint/UnusedMethodArgument
        mset_sync(hash, ttl: ttl)
      end

      def mset_sync(hash, ttl: nil, phi: false)
        ttl = enforce_phi_ttl(ttl, phi: phi) if phi
        @store.mset(hash, ttl: ttl)
      end

      def flush
        @store.clear
        log.info 'Legion::Cache::Memory flushed'
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memory_flush)
        false
      end

      def close
        shutdown
      end

      def shutdown
        @store.close
        @connected.make_false
        log.info 'Legion::Cache::Memory shut down'
        false
      rescue StandardError => e
        @connected.make_false
        handle_exception(e, level: :warn, handled: true, operation: :memory_shutdown)
        false
      end

      def reset!
        @store.clear
        @store.max_entries = ExpiringStore::DEFAULT_MAX_ENTRIES
        @connected.make_false
        log.info 'Legion::Cache::Memory state reset'
        false
      end

      def size = 1
      def available = 1

      private

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
