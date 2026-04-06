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
require 'legion/cache/helper'

module Legion
  module Cache
    extend Legion::Logging::Helper

    @async_writer = Legion::Cache::AsyncWriter.new

    class << self
      include Legion::Logging::Helper

      def enabled?
        return true unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :enabled) != false
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_enabled)
        true
      end

      def connected?
        @connected == true
      end

      def driver_name
        return 'memory' if @using_memory
        return 'local' if @using_local

        @active_shared_driver || configured_shared_driver
      end

      def stats
        {
          driver: driver_name,
          servers: resolved_servers,
          enabled: enabled?,
          connected: connected?,
          using_local: using_local?,
          using_memory: using_memory?,
          pool_size: safe_pool_size,
          pool_available: safe_pool_available,
          async_pool_size: async_writer_pool_size,
          async_queue_depth: async_writer_queue_depth,
          async_processed: async_writer_processed_count,
          reconnect_attempts: reconnector_attempts,
          uptime: uptime_seconds
        }.freeze
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_stats)
        { error: e.message }.freeze
      end

      def setup(**)
        return Legion::Settings[:cache][:connected] = true if connected?

        @setup_at = Time.now

        async_writer.start

        if ENV['LEGION_MODE'] == 'lite'
          Legion::Cache::Memory.setup
          @using_memory = true
          @connected = true
          Legion::Settings[:cache][:connected] = true
          log.info 'Legion::Cache using in-memory adapter (lite mode)'
          return
        end

        log.debug { "Legion::Cache setup driver=#{Legion::Settings[:cache][:driver]} servers=#{Array(Legion::Settings[:cache][:servers]).size}" }
        setup_local
        setup_shared(**)
      end

      def shutdown
        log.info 'Shutting down Legion::Cache'
        stop_reconnector
        async_writer.stop
        if @using_memory
          Legion::Cache::Memory.shutdown
        else
          close unless @using_local
          Legion::Cache::Local.shutdown if Legion::Cache::Local.connected?
        end
        @using_local = false
        @using_memory = false
        @connected = false
        Legion::Settings[:cache][:connected] = false
      end

      def local
        Legion::Cache::Local
      end

      def using_local?
        @using_local == true
      end

      def using_memory?
        @using_memory == true
      end

      def client(**opts)
        if ENV['LEGION_MODE'] == 'lite'
          Legion::Cache::Memory.setup unless Legion::Cache::Memory.connected?
          @using_memory = true
          @using_local = false
          @connected = true
          @active_shared_driver = nil
          Legion::Settings[:cache][:connected] = true if defined?(Legion::Settings)
          return Legion::Cache::Memory.client
        end

        configure_shared_adapter!(opts[:driver])
        @using_memory = false
        @using_local = false
        result = super
        @connected = true
        Legion::Settings[:cache][:connected] = true if defined?(Legion::Settings)
        result
      rescue StandardError
        @connected = false
        Legion::Settings[:cache][:connected] = false if defined?(Legion::Settings)
        raise
      end

      def get(key)
        return Legion::Cache::Memory.get(key) if @using_memory
        return Legion::Cache::Local.get(key) if @using_local

        configure_shared_adapter!
        super
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_get, key: key)
        nil
      end

      def phi_max_ttl
        return 3600 unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :compliance, :phi_max_ttl) || 3600
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_phi_max_ttl)
        3600
      end

      def enforce_phi_ttl(ttl, phi: false, **)
        return ttl unless phi == true

        max = phi_max_ttl
        [ttl, max].min
      end

      def set(key, value, ttl: nil, async: true, phi: false)
        effective_ttl = resolve_ttl(ttl, phi: phi)

        if async && async_writer.running?
          async_writer.enqueue { set_internal(key, value, ttl: effective_ttl) }
          true
        else
          set_internal(key, value, ttl: effective_ttl)
        end
      end

      def set_sync(key, value, ttl: nil, **)
        return Legion::Cache::Memory.set_sync(key, value, ttl: ttl) if @using_memory
        return Legion::Cache::Local.set_sync(key, value, ttl: ttl) if @using_local

        configure_shared_adapter!
        super
      end

      def fetch(key, ttl: nil, &)
        return Legion::Cache::Memory.fetch(key, ttl: ttl, &) if @using_memory
        return Legion::Cache::Local.fetch(key, ttl: ttl, &) if @using_local

        configure_shared_adapter!
        super
      end

      def delete(key, async: true)
        if async && async_writer.running?
          async_writer.enqueue { delete_internal(key) }
          true
        else
          delete_internal(key)
        end
      end

      def delete_sync(key)
        return Legion::Cache::Memory.delete_sync(key) if @using_memory
        return Legion::Cache::Local.delete_sync(key) if @using_local

        configure_shared_adapter!
        super
      end

      def flush
        return Legion::Cache::Memory.flush if @using_memory
        return Legion::Cache::Local.flush if @using_local

        configure_shared_adapter!
        super
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?
        return keys.to_h { |key| [key, Legion::Cache::Memory.get(key)] } if @using_memory
        return Legion::Cache::Local.mget(*keys) if @using_local

        configure_shared_adapter!
        super
      end

      def mset(hash, ttl: nil, async: true)
        return true if hash.empty?

        if async && async_writer.running?
          async_writer.enqueue { mset_internal(hash, ttl: ttl) }
          true
        else
          mset_internal(hash, ttl: ttl)
        end
      end

      def mset_sync(hash, ttl: nil, **)
        return true if hash.empty?
        return hash.each { |key, value| Legion::Cache::Memory.set_sync(key, value, ttl: ttl) } && true if @using_memory
        return Legion::Cache::Local.mset(hash, ttl: ttl) if @using_local

        configure_shared_adapter!
        super
      end

      def close
        if @using_memory
          Legion::Cache::Memory.shutdown
          @using_memory = false
          @connected = false
          Legion::Settings[:cache][:connected] = false if defined?(Legion::Settings)
          return false
        end

        if @using_local
          Legion::Cache::Local.close
          @using_local = false
          @connected = false
          Legion::Settings[:cache][:connected] = false if defined?(Legion::Settings)
          return false
        end

        return false unless instance_variable_defined?(:@client) && @client

        configure_shared_adapter!
        result = super
        @connected = false
        Legion::Settings[:cache][:connected] = false if defined?(Legion::Settings)
        result
      end

      def restart(**opts)
        configure_shared_adapter!(opts[:driver])
        @using_memory = false
        @using_local = false
        result = super
        @connected = true
        Legion::Settings[:cache][:connected] = true if defined?(Legion::Settings)
        result
      end

      def size
        return Legion::Cache::Memory.size if @using_memory
        return Legion::Cache::Local.size if @using_local

        configure_shared_adapter!
        super
      end

      def available
        return Legion::Cache::Memory.available if @using_memory
        return Legion::Cache::Local.available if @using_local

        configure_shared_adapter!
        super
      end

      def pool_size
        return Legion::Cache::Memory.size if @using_memory
        return Legion::Cache::Local.pool_size if @using_local

        configure_shared_adapter!
        super
      end

      def timeout
        return 0 if @using_memory
        return Legion::Cache::Local.timeout if @using_local

        configure_shared_adapter!
        super
      end

      private

      def async_writer
        Legion::Cache.instance_variable_get(:@async_writer)
      end

      def set_internal(key, value, ttl: nil)
        return Legion::Cache::Memory.set(key, value, ttl: ttl) if @using_memory
        return Legion::Cache::Local.set(key, value, ttl: ttl) if @using_local

        configure_shared_adapter!
        set_sync(key, value, ttl: ttl)
      end

      def delete_internal(key)
        return Legion::Cache::Memory.delete(key) if @using_memory
        return Legion::Cache::Local.delete(key) if @using_local

        configure_shared_adapter!
        delete_sync(key)
      end

      def mset_internal(hash, ttl: nil)
        return hash.each { |key, value| Legion::Cache::Memory.set(key, value, ttl: ttl) } && true if @using_memory
        return Legion::Cache::Local.mset(hash, ttl: ttl) if @using_local

        configure_shared_adapter!
        mset_sync(hash, ttl: ttl)
      end

      def resolve_ttl(ttl, phi: false)
        effective = ttl || default_ttl
        enforce_phi_ttl(effective, phi: phi)
      end

      def default_ttl
        return 3600 unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :default_ttl) || 3600
      rescue StandardError
        3600
      end

      def setup_local
        return if Legion::Cache::Local.connected?

        Legion::Cache::Local.setup
      rescue StandardError => e
        report_exception(e, level: :warn, handled: true, operation: :setup_local)
      end

      def setup_shared(**)
        client(**Legion::Settings[:cache], logger: log, **)
        @connected = true
        @using_local = false
        Legion::Settings[:cache][:connected] = true
        driver = Legion::Settings[:cache][:driver] || 'dalli'
        servers = Array(Legion::Settings[:cache][:servers]).join(', ')
        log.info "Legion::Cache connected (driver=#{driver}) to #{servers}"
      rescue StandardError => e
        report_exception(e, level: :warn, handled: true, operation: :setup_shared, fallback: :local)
        if Legion::Cache::Local.connected?
          @using_local = true
          @connected = true
          Legion::Settings[:cache][:connected] = true
          log.info 'Legion::Cache fell back to Local cache'
        else
          @connected = false
          Legion::Settings[:cache][:connected] = false
          log.error 'Legion::Cache shared and local adapters are unavailable'
          start_reconnector
        end
      end

      def report_exception(exception, level:, handled:, **)
        handle_exception(exception, level: level, handled: handled, **)
      end

      def configure_shared_adapter!(requested_driver = nil)
        driver = Legion::Cache::Settings.normalize_driver(requested_driver || configured_shared_driver)
        return if @active_shared_driver == driver

        close_existing_shared_client
        extend build_shared_adapter(driver)

        @active_shared_driver = driver
        log.info "Legion::Cache selected shared adapter=#{driver}"
      end

      def configured_shared_driver
        if defined?(Legion::Settings)
          Legion::Cache::Settings.normalize_driver(Legion::Settings.dig(:cache, :driver) || Legion::Cache::Settings.driver)
        else
          Legion::Cache::Settings.driver
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_configured_shared_driver)
        'dalli'
      end

      def build_shared_adapter(driver)
        case Legion::Cache::Settings.normalize_driver(driver)
        when 'redis'
          Legion::Cache::Redis.dup
        else
          Legion::Cache::Memcached.dup
        end
      end

      def close_existing_shared_client
        return unless instance_variable_defined?(:@client) && @client

        @client.shutdown(&:close)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_close_existing_shared_client)
      ensure
        @client = nil
        @connected = false
      end

      def resolved_servers
        return [] if @using_memory

        Array(Legion::Settings.dig(:cache, :servers))
      rescue StandardError
        []
      end

      def safe_pool_size
        return 1 if @using_memory
        return 0 unless connected?

        pool_size
      rescue StandardError
        0
      end

      def safe_pool_available
        return 1 if @using_memory
        return 0 unless connected?

        available
      rescue StandardError
        0
      end

      def async_writer_pool_size
        async_writer.pool_size
      rescue StandardError
        0
      end

      def async_writer_queue_depth
        async_writer.queue_depth
      rescue StandardError
        0
      end

      def async_writer_processed_count
        async_writer.processed_count
      rescue StandardError
        0
      end

      def reconnector_attempts
        @reconnector&.attempts || 0
      end

      def start_reconnector
        return unless enabled?

        stop_reconnector
        @reconnector = Legion::Cache::Reconnector.new(
          tier: :shared,
          connect_block: -> { setup_shared },
          enabled_block: -> { enabled? }
        )
        @reconnector.start
        log.info 'Legion::Cache started background reconnector for shared tier'
      end

      def stop_reconnector
        @reconnector&.stop
        @reconnector = nil
      end

      def uptime_seconds
        return 0 unless @setup_at

        (Time.now - @setup_at).to_i
      rescue StandardError
        0
      end
    end
  end
end
