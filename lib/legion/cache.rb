# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/cache/version'
require 'legion/cache/settings'
require 'legion/cache/cacheable'
require 'legion/cache/memcached'
require 'legion/cache/redis'
require 'legion/cache/redis_hash'
require 'legion/cache/memory'
require 'legion/cache/local'
require 'legion/cache/async_writer'
require 'legion/cache/reconnector'
require 'concurrent'
require 'legion/cache/helper'

module Legion
  module Cache
    extend Legion::Logging::Helper

    @async_writer = Legion::Cache::AsyncWriter.new(settings_key: :cache)
    @connected = Concurrent::AtomicBoolean.new(false)
    @using_local = Concurrent::AtomicBoolean.new(false)
    @using_memory = Concurrent::AtomicBoolean.new(false)

    class << self
      include Legion::Logging::Helper
      include Legion::Cache::Pool

      def enabled?
        !defined?(Legion::Settings) || Legion::Settings.dig(:cache, :enabled) != false
      end

      def connected?
        return false unless enabled? && @connected.value
        return Legion::Cache::Local.enabled? && Legion::Cache::Local.connected? if using_local?

        true
      end

      def driver_name
        return 'memory' if using_memory?
        return 'local' if using_local?

        @active_shared_driver || configured_shared_driver
      end

      def stats
        {
          driver: driver_name, servers: resolved_servers, enabled: enabled?, connected: connected?,
          using_local: using_local?, using_memory: using_memory?, pool_size: pool_size, pool_available: available,
          async_pool_size: async_writer.pool_size, async_queue_depth: async_writer.queue_depth,
          async_processed: async_writer.processed_count, async_failed: async_writer.failed_count,
          reconnect_attempts: @reconnector&.attempts || 0, uptime: @setup_at ? (Time.now - @setup_at).to_i : 0
        }.freeze
      end

      def setup(**opts)
        return false unless enabled?
        return true if connected?

        @initialized = true
        @connection_options = Legion::Cache::Settings.connection_options(@connection_options || {}, opts)
        @setup_at = Time.now
        async_writer.start
        if ENV['LEGION_MODE'] == 'lite'
          Legion::Cache::Memory.setup
          @using_memory.make_true
          @using_local.make_false
          cache_mark_connected(true)
          return true
        end

        Legion::Cache::Local.setup
        setup_shared
      end

      def shutdown
        async_writer.stop(timeout: configured_shutdown_timeout)
        stop_reconnector
        close_existing_shared_client
        Legion::Cache::Local.shutdown
        Legion::Cache::Memory.shutdown if using_memory?
        @using_local.make_false
        @using_memory.make_false
        cache_mark_connected(false)
        @initialized = false
      end

      def local
        Legion::Cache::Local
      end

      def pool
        @client
      end

      def using_local?
        @using_local.value
      end

      def using_memory?
        @using_memory.value
      end

      def client(**)
        return nil unless enabled?

        setup(**) unless @initialized
        return Legion::Cache::Memory.client if using_memory?
        return Legion::Cache::Local.client if using_local?
        return nil unless connected?

        @client
      end

      def get(key)
        cache_operation(:get, key, failure: nil)
      end

      def phi_max_ttl
        configured = defined?(Legion::Settings) ? Legion::Settings.dig(:cache, :compliance, :phi_max_ttl) : nil
        return 3600 if configured.nil?
        return configured if configured.is_a?(Numeric) && configured.finite? && configured.positive?

        raise ArgumentError, 'phi_max_ttl must be positive and finite'
      end

      def enforce_phi_ttl(ttl, phi: false, **)
        return ttl unless phi == true
        raise ArgumentError, 'PHI ttl must be numeric and finite' unless ttl.nil? || (ttl.is_a?(Numeric) && ttl.finite?)
        return phi_max_ttl if ttl.nil? || !ttl.positive?

        [ttl, phi_max_ttl].min
      end

      def set(key, value, ttl: nil, async: true, phi: false)
        return false unless enabled?

        setup unless @initialized || connected?
        return false unless connected?

        effective_ttl = resolve_ttl(ttl, phi: phi)
        if async
          async_writer.enqueue(key: key) { set_sync(key, value, ttl: effective_ttl) }
        else
          set_sync(key, value, ttl: effective_ttl)
        end
      end

      def set_nx(key, value, ttl: nil, phi: false)
        return false unless enabled?

        cache_operation(:set_nx, key, value, ttl: resolve_ttl(ttl, phi: phi), failure: false)
      end

      def set_sync(key, value, ttl: nil, phi: false, **)
        return false unless enabled?

        cache_operation(:set_sync, key, value, ttl: resolve_ttl(ttl, phi: phi), failure: false)
      end

      def cas(key, ttl: nil, phi: false, &)
        return false unless enabled?

        cache_operation(:cas, key, ttl: resolve_ttl(ttl, phi: phi), failure: false, &)
      end

      def fetch(key, ttl: nil)
        cached = get(key)
        return cached unless cached.nil?
        return nil unless block_given?

        value = yield
        set_sync(key, value, ttl: ttl)
        value
      end

      def delete(key, async: true)
        return false unless enabled?

        setup unless @initialized || connected?
        return false unless connected?

        if async
          async_writer.enqueue(key: key) { delete_sync(key) }
        else
          delete_sync(key)
        end
      end

      def delete_sync(key)
        cache_operation(:delete_sync, key, failure: false)
      end

      def flush
        cache_operation(:flush, failure: false)
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        cache_operation(:mget, *keys, failure: {})
      end

      def mset(hash, ttl: nil, async: true, phi: false)
        return false unless enabled?
        return mset_sync(hash, ttl: ttl, phi: phi) unless async

        setup unless @initialized || connected?
        return false unless connected?

        effective_ttl = resolve_ttl(ttl, phi: phi)
        accepted = true
        hash.each do |key, value|
          result = async_writer.enqueue(key: key) { set_sync(key, value, ttl: effective_ttl) }
          accepted = false unless result
        end
        accepted
      end

      def mset_sync(hash, ttl: nil, phi: false, **)
        return false unless enabled?
        return true if hash.empty?

        cache_operation(:mset_sync, hash, ttl: resolve_ttl(ttl, phi: phi), failure: false)
      end

      def close
        shutdown
      end

      def restart(**)
        shutdown
        setup(**)
      end

      def size
        pool_size
      end

      def available
        return 0 unless connected?
        return Legion::Cache::Memory.available if using_memory?
        return Legion::Cache::Local.available if using_local?

        @client&.available || 0
      end

      def pool_size
        return 0 unless connected?
        return Legion::Cache::Memory.size if using_memory?
        return Legion::Cache::Local.pool_size if using_local?

        @client&.size || 0
      end

      def timeout
        return 0 unless connected?
        return 0 if using_memory?
        return Legion::Cache::Local.timeout if using_local?

        @timeout || shared_settings[:timeout] || 5
      end

      private

      attr_reader :async_writer

      def cache_operation(operation, *, failure:, **, &block)
        return failure unless enabled?

        setup unless @initialized || connected?
        return failure unless connected?

        return Legion::Cache::Memory.public_send(operation, *, **, &block) if using_memory?
        return Legion::Cache::Local.public_send(operation, *, **, &block) if using_local?

        configure_shared_adapter!
        user_error = nil
        guarded = if block
                    proc do |value|
                      block.call(value)
                    rescue StandardError => e
                      user_error = e
                      raise
                    end
                  end
        begin
          result = @shared_adapter.instance_method(operation).bind_call(self, *, **, &guarded)
        rescue StandardError => e
          raise if e.equal?(user_error) || !cache_connection_error?(e)

          cache_backend_failed(e)
          handle_exception(e, level: :warn, handled: true, operation: operation)
          result = failure
        end
        return Legion::Cache::Local.public_send(operation, *, **, &block) if using_local? && connected?

        connected? ? result : failure
      end

      def cache_mark_connected(value)
        @connected.value = value
        Legion::Settings[:cache][:connected] = value if defined?(Legion::Settings)
      end

      def cache_backend_failed(error)
        return unless cache_connection_error?(error)

        cache_mark_connected(false)
        select_local_fallback
        start_reconnector
      end

      def select_local_fallback
        available = enabled? && shared_settings[:failback_to_local] != false &&
                    Legion::Cache::Local.enabled? && Legion::Cache::Local.connected?
        @using_local.value = available
        cache_mark_connected(available)
        available
      end

      def resolve_ttl(ttl, phi: false)
        enforce_phi_ttl(ttl || shared_settings[:default_ttl] || 3600, phi: phi)
      end

      def setup_shared
        configure_shared_adapter!
        settings = Legion::Cache::Settings.connection_options(shared_settings, @connection_options || {})
        @shared_adapter.instance_method(:client).bind_call(self, **settings, logger: log)
        @using_local.make_false
        @using_memory.make_false
        cache_mark_connected(true)
        true
      rescue StandardError => e
        close_existing_shared_client
        raise unless cache_connection_error?(e)

        handle_exception(e, level: :warn, handled: true, operation: :setup_shared)
        result = select_local_fallback
        start_reconnector
        result
      end

      def reconnect_shared!
        return false unless reconnect_enabled?

        close_existing_shared_client
        configure_shared_adapter!
        settings = Legion::Cache::Settings.connection_options(shared_settings, @connection_options || {})
        @shared_adapter.instance_method(:client).bind_call(self, **settings, logger: log)
        unless reconnect_enabled?
          close_existing_shared_client
          select_local_fallback
          return false
        end

        @using_local.make_false
        cache_mark_connected(true)
        true
      rescue StandardError => e
        close_existing_shared_client
        select_local_fallback
        raise e
      end

      def configure_shared_adapter!(requested_driver = nil)
        driver = Legion::Cache::Settings.normalize_driver(requested_driver || @connection_options&.dig(:driver) || configured_shared_driver)
        return if @active_shared_driver == driver && @shared_adapter

        close_existing_shared_client
        @shared_adapter = build_shared_adapter(driver)
        extend @shared_adapter

        @active_shared_driver = driver
      end

      def configured_shared_driver
        Legion::Cache::Settings.normalize_driver(shared_settings[:driver] || Legion::Cache::Settings.driver)
      end

      def build_shared_adapter(driver)
        driver == 'redis' ? Legion::Cache::Redis.dup : Legion::Cache::Memcached.dup
      end

      def close_existing_shared_client
        pool = @client
        @client = nil
        pool&.shutdown(&:close)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_close_existing_shared_client)
      end

      def shared_settings
        return Legion::Cache::Settings.default unless defined?(Legion::Settings)

        Legion::Settings[:cache] || Legion::Cache::Settings.default
      end

      def resolved_servers
        using_memory? ? [] : Array(shared_settings[:servers])
      end

      def configured_shutdown_timeout
        shared_settings.dig(:async, :shutdown_timeout) || 5
      end

      def reconnect_enabled?
        enabled? && shared_settings.dig(:reconnect, :enabled) != false
      end

      def start_reconnector
        return unless reconnect_enabled?
        return if @reconnector&.running?

        @reconnector = Legion::Cache::Reconnector.new(
          tier: :shared, connect_block: -> { reconnect_shared! },
          enabled_block: -> { reconnect_enabled? }, settings_key: :cache
        )
        @reconnector.start
      end

      def stop_reconnector
        @reconnector&.stop
        @reconnector = nil
      end
    end
  end
end
