# frozen_string_literal: true

require 'legion/cache/settings'

module Legion
  module Cache
    module Local
      class << self
        def setup(**)
          return if @connected

          settings = local_settings
          return unless settings[:enabled]

          driver_name = settings[:driver] || Legion::Cache::Settings.driver
          @driver = build_driver(driver_name)
          @driver.client(**settings, **)
          @connected = true
          Legion::Logging.info "Legion::Cache::Local connected (#{driver_name})" if defined?(Legion::Logging)
        rescue StandardError => e
          Legion::Logging.warn "Legion::Cache::Local setup failed: #{e.message}" if defined?(Legion::Logging)
          @connected = false
        end

        def shutdown
          return unless @connected

          Legion::Logging.info 'Shutting down Legion::Cache::Local' if defined?(Legion::Logging)
          @driver&.close
          @driver = nil
          @connected = false
        end

        def connected?
          @connected == true
        end

        def get(key)
          @driver.get(key)
        end

        def set(key, value, ttl = 180)
          @driver.set(key, value, ttl)
        end

        def fetch(key, ttl = nil)
          @driver.fetch(key, ttl)
        end

        def delete(key)
          @driver.delete(key)
        end

        def flush(delay = 0)
          @driver.flush(delay)
        end

        def client
          @driver&.client
        end

        def close
          @driver&.close
          @connected = false
        end

        def restart(**opts)
          settings = local_settings
          @driver&.restart(**settings.merge(opts))
          @connected = true
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
          @connected = false
        end

        private

        def build_driver(driver_name)
          case driver_name
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
