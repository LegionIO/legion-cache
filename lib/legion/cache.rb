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
require 'legion/cache/helper'

module Legion
  module Cache
    extend Legion::Logging::Helper

    if Legion::Cache::Settings.normalize_driver(Legion::Settings[:cache][:driver]) == 'redis'
      extend Legion::Cache::Redis
    else
      extend Legion::Cache::Memcached
    end

    class << self
      include Legion::Logging::Helper

      def setup(**)
        return Legion::Settings[:cache][:connected] = true if connected?

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

      def get(key)
        return Legion::Cache::Memory.get(key) if @using_memory
        return Legion::Cache::Local.get(key) if @using_local

        super
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

      def set(key, value, ttl = nil, **opts)
        ttl = opts.delete(:ttl) || ttl || 180
        effective_ttl = enforce_phi_ttl(ttl, **opts)
        return Legion::Cache::Memory.set(key, value, effective_ttl) if @using_memory
        return Legion::Cache::Local.set(key, value, effective_ttl) if @using_local

        super(key, value, effective_ttl)
      end

      def fetch(key, ttl = nil)
        return Legion::Cache::Memory.fetch(key, ttl) if @using_memory
        return Legion::Cache::Local.fetch(key, ttl) if @using_local

        super
      end

      def delete(key)
        return Legion::Cache::Memory.delete(key) if @using_memory
        return Legion::Cache::Local.delete(key) if @using_local

        super
      end

      def flush(delay = 0)
        return Legion::Cache::Memory.flush(delay) if @using_memory
        return Legion::Cache::Local.flush(delay) if @using_local

        super
      end

      private

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
        end
      end

      def report_exception(exception, level:, handled:, **)
        handle_exception(exception, level: level, handled: handled, **)
      end
    end
  end
end
