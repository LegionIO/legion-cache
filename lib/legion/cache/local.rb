# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'
require 'legion/cache/settings'

module Legion
  module Cache
    module Local
      @connected = Concurrent::AtomicBoolean.new(false)

      class << self
        include Legion::Logging::Helper

        def setup(**)
          return unless enabled?
          return if connected?

          settings = local_settings
          return unless settings[:enabled]

          driver_name = settings[:driver] || Legion::Cache::Settings.driver
          @driver_name = Legion::Cache::Settings.normalize_driver(driver_name)
          @driver = build_driver(driver_name)
          @driver.client(**settings, logger: log, **)
          @connected.make_true
          servers = Array(settings[:servers]).join(', ')
          log.info "Legion::Cache::Local connected (#{driver_name}) to #{servers}"
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_setup, driver: driver_name)
          @connected.make_false
        end

        def shutdown
          return unless @connected

          log.info 'Shutting down Legion::Cache::Local'
          @driver&.close
          @driver = nil
          @driver_name = nil
          @connected.make_false
        end

        def enabled?
          return true unless defined?(Legion::Settings)

          Legion::Settings.dig(:cache_local, :enabled) != false
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_enabled)
          true
        end

        def connected?
          @connected&.true? || false
        end

        def driver_name
          @driver_name || Legion::Cache::Settings.normalize_driver(local_settings[:driver] || Legion::Cache::Settings.driver)
        end

        def get(key)
          result = @driver.get(key)
          log.debug { "[cache:local] GET #{key} hit=#{!result.nil?}" }
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_get, key: key)
          nil
        end

        def set(key, value, ttl: nil, **)
          set_sync(key, value, ttl: ttl, **)
        end

        def set_sync(key, value, ttl: nil, **)
          effective_ttl = ttl || local_default_ttl
          result = @driver.set_sync(key, value, ttl: effective_ttl)
          log.debug { "[cache:local] SET #{key} ttl=#{effective_ttl} success=#{result}" }
          result
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :cache_local_set_sync, key: key, ttl: effective_ttl)
          raise
        end

        def fetch(key, ttl: nil, &)
          result = @driver.fetch(key, ttl: ttl, &)
          log.debug { "[cache:local] FETCH #{key} hit=#{!result.nil?}" }
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_fetch, key: key, ttl: ttl)
          nil
        end

        def delete(key, **)
          delete_sync(key)
        end

        def delete_sync(key)
          result = @driver.delete_sync(key)
          log.debug { "[cache:local] DELETE #{key} success=#{result}" }
          result
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :cache_local_delete_sync, key: key)
          raise
        end

        def flush
          result = @driver.flush
          log.debug { '[cache:local] FLUSH completed' }
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_flush)
          nil
        end

        def mget(*keys)
          keys = keys.flatten
          return {} if keys.empty?

          keys.to_h { |key| [key, get(key)] }
        end

        def mset(hash, ttl: nil, **)
          return true if hash.empty?

          hash.each { |key, value| set(key, value, ttl: ttl) }
          true
        end

        def stats
          {
            driver:    driver_name,
            servers:   local_servers,
            enabled:   enabled?,
            connected: connected?
          }.freeze
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_stats)
          { error: e.message }.freeze
        end

        def client
          @driver&.client
        end

        def close
          @driver&.close
          @driver = nil
          @driver_name = nil
          @connected.make_false
          log.info 'Legion::Cache::Local pool closed'
          @connected
        end

        def restart(**opts)
          settings = local_settings
          @driver&.restart(**settings.merge(opts, logger: log))
          @connected.make_true
          log.info 'Legion::Cache::Local pool restarted'
          @connected
        end

        def size
          @driver.size
        end

        def available
          @driver.available
        end

        def pool_size
          @driver.pool_size
        end

        def timeout
          @driver.timeout
        end

        def reset!
          @driver = nil
          @driver_name = nil
          @connected.make_false
          log.debug 'Legion::Cache::Local state reset'
          @connected
        end

        private

        def local_servers
          Array(local_settings[:servers])
        rescue StandardError
          []
        end

        def local_default_ttl
          return 21_600 unless defined?(Legion::Settings)

          Legion::Settings.dig(:cache_local, :default_ttl) || 21_600
        rescue StandardError
          21_600
        end

        def build_driver(driver_name)
          case Legion::Cache::Settings.normalize_driver(driver_name)
          when 'redis'
            require 'legion/cache/redis'
            Legion::Cache::Redis.dup
          else
            require 'legion/cache/memcached'
            Legion::Cache::Memcached.dup
          end
        end

        def local_settings
          return Legion::Cache::Settings.local unless defined?(Legion::Settings)

          Legion::Settings[:cache_local] || Legion::Cache::Settings.local
        end
      end
    end
  end
end
