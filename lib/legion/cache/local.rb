# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'
require 'legion/cache/settings'
require 'legion/cache/async_writer'
require 'legion/cache/pool'

module Legion
  module Cache
    module Local
      @connected = Concurrent::AtomicBoolean.new(false)
      @async_writer = Legion::Cache::AsyncWriter.new(settings_key: :cache_local)

      class << self
        include Legion::Logging::Helper
        include Legion::Cache::Pool

        def setup(**opts)
          return false unless enabled?
          return true if connected?

          @connection_options = Legion::Cache::Settings.connection_options(@connection_options || {}, opts)
          settings = Legion::Cache::Settings.connection_options(local_settings, @connection_options)
          driver_name = settings[:driver] || Legion::Cache::Settings.driver
          @driver_name = Legion::Cache::Settings.normalize_driver(driver_name)
          @driver = build_driver(driver_name)
          @driver.instance_variable_set(:@cache_settings, settings)
          @driver.instance_variable_set(:@cache_failure_callback, ->(error) { cache_backend_failed(error) })
          @driver.client(**settings, logger: log)
          @async_writer.start
          cache_mark_connected(true)
          true
        rescue StandardError => e
          @driver&.close
          @driver = nil
          cache_mark_connected(false)
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_setup, driver: driver_name)
          raise unless cache_connection_error?(e)

          false
        end

        def shutdown
          @async_writer.stop
          @driver&.close
          @driver = nil
          @driver_name = nil
          cache_mark_connected(false)
        end

        def enabled?
          !defined?(Legion::Settings) || Legion::Settings.dig(:cache_local, :enabled) != false
        end

        def connected?
          enabled? && @connected.value
        end

        def driver_name
          @driver_name || Legion::Cache::Settings.normalize_driver(local_settings[:driver] || Legion::Cache::Settings.driver)
        end

        def get(key)
          local_operation(:get, key, failure: nil)
        end

        def set(key, value, ttl: nil, async: true, phi: false, **)
          return false unless enabled? && connected?

          ttl = local_write_ttl(ttl, phi: phi)
          if async
            @async_writer.enqueue(key: key) { set_sync(key, value, ttl: ttl) }
          else
            set_sync(key, value, ttl: ttl)
          end
        end

        def set_sync(key, value, ttl: nil, phi: false, **)
          local_operation(:set_sync, key, value, ttl: local_write_ttl(ttl, phi: phi), failure: false)
        end

        def set_nx(key, value, ttl: nil, phi: false)
          local_operation(:set_nx, key, value, ttl: local_write_ttl(ttl, phi: phi), failure: false)
        end

        def cas(key, ttl: nil, phi: false, &block)
          local_operation(:cas, key, ttl: local_write_ttl(ttl, phi: phi), failure: false, &block)
        end

        def fetch(key, ttl: nil)
          cached = get(key)
          return cached unless cached.nil?
          return nil unless block_given?

          value = yield
          set_sync(key, value, ttl: ttl)
          value
        end

        def delete(key, async: true, **)
          return false unless enabled? && connected?

          if async
            @async_writer.enqueue(key: key) { delete_sync(key) }
          else
            delete_sync(key)
          end
        end

        def delete_sync(key)
          local_operation(:delete_sync, key, failure: false)
        end

        def flush
          local_operation(:flush, failure: false)
        end

        def mget(*keys)
          return {} unless enabled?

          keys.flatten.to_h { |key| [key, get(key)] }
        end

        def mset(hash, ttl: nil, async: true, phi: false, **)
          return false unless enabled?

          accepted = true
          hash.each do |key, value|
            result = set(key, value, ttl: ttl, async: async, phi: phi)
            accepted = false unless result
          end
          accepted
        end

        def mset_sync(hash, ttl: nil, phi: false, **)
          mset(hash, ttl: ttl, async: false, phi: phi)
        end

        def stats
          { driver: driver_name, servers: Array(local_settings[:servers]), enabled: enabled?, connected: connected? }.freeze
        end

        def client(**opts)
          return nil unless enabled?

          setup(**opts) unless @driver
          @driver&.client if connected?
        end

        def close
          shutdown
        end

        def restart(**opts)
          shutdown
          setup(**opts)
        end

        def size
          connected? ? @driver.size : 0
        end

        def available
          connected? ? @driver.available : 0
        end

        def pool_size
          connected? ? @driver.pool_size : 0
        end

        def timeout
          connected? ? @driver.timeout : 0
        end

        def reset!
          shutdown
          @connection_options = nil
        end

        private

        def local_operation(operation, *args, failure:, **opts, &block)
          return failure unless enabled? && connected? && @driver

          user_error = nil
          guarded = if block
                      proc do |value|
                        block.call(value)
                      rescue StandardError => e
                        user_error = e
                        raise
                      end
                    end
          @driver.public_send(operation, *args, **opts, &guarded)
        rescue StandardError => e
          raise if e.equal?(user_error) || !cache_connection_error?(e)

          cache_backend_failed(e)
          handle_exception(e, level: :warn, handled: true, operation: operation)
          failure
        end

        def local_write_ttl(ttl, phi:)
          effective = ttl || local_settings[:default_ttl] || 21_600
          return effective unless phi

          Legion::Cache.enforce_phi_ttl(effective, phi: phi)
        end

        def build_driver(driver_name)
          case Legion::Cache::Settings.normalize_driver(driver_name)
          when 'redis'
            require 'legion/cache/redis'
            Object.new.extend(Legion::Cache::Redis, Legion::Logging::Helper)
          else
            require 'legion/cache/memcached'
            Object.new.extend(Legion::Cache::Memcached, Legion::Logging::Helper)
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
