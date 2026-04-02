# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/cache/settings'

module Legion
  module Cache
    module Local
      class << self
        include Legion::Logging::Helper

        def setup(**)
          return if @connected

          settings = local_settings
          return unless settings[:enabled]

          driver_name = settings[:driver] || Legion::Cache::Settings.driver
          @driver_name = Legion::Cache::Settings.normalize_driver(driver_name)
          @driver = build_driver(driver_name)
          @driver.client(**settings, logger: log, **)
          @connected = true
          servers = Array(settings[:servers]).join(', ')
          log.info "Legion::Cache::Local connected (#{driver_name}) to #{servers}"
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :cache_local_setup, driver: driver_name)
          @connected = false
        end

        def shutdown
          return unless @connected

          log.info 'Shutting down Legion::Cache::Local'
          @driver&.close
          @driver = nil
          @driver_name = nil
          @connected = false
        end

        def connected?
          @connected == true
        end

        def driver_name
          @driver_name || Legion::Cache::Settings.normalize_driver(local_settings[:driver] || Legion::Cache::Settings.driver)
        end

        def get(key)
          result = @driver.get(key)
          log.debug "[cache:local] GET #{key} hit=#{!result.nil?}"
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: :cache_local_get, key: key)
          raise
        end

        def set(key, value, ttl = 180)
          result = @driver.set(key, value, ttl)
          log.debug "[cache:local] SET #{key} ttl=#{ttl} success=#{result}"
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: :cache_local_set, key: key, ttl: ttl)
          raise
        end

        def fetch(key, ttl = nil, &)
          result = @driver.fetch(key, ttl, &)
          log.debug "[cache:local] FETCH #{key} hit=#{!result.nil?}"
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: :cache_local_fetch, key: key, ttl: ttl)
          raise
        end

        def delete(key)
          result = @driver.delete(key)
          log.debug "[cache:local] DELETE #{key} success=#{result}"
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: :cache_local_delete, key: key)
          raise
        end

        def flush(delay = 0)
          result = @driver.flush(delay)
          log.debug '[cache:local] FLUSH completed'
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: :cache_local_flush, delay: delay)
          raise
        end

        def client
          @driver&.client
        end

        def close
          @driver&.close
          @driver = nil
          @driver_name = nil
          @connected = false
          log.info 'Legion::Cache::Local pool closed'
          @connected
        end

        def restart(**opts)
          settings = local_settings
          @driver&.restart(**settings.merge(opts, logger: log))
          @connected = true
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
          @connected = false
          log.debug 'Legion::Cache::Local state reset'
          @connected
        end

        private

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
