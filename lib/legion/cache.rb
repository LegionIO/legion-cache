# frozen_string_literal: true

require 'legion/cache/version'
require 'legion/cache/settings'
require 'legion/cache/cacheable'

require 'legion/cache/memcached'
require 'legion/cache/redis'
require 'legion/cache/memory'
require 'legion/cache/local'
require 'legion/cache/helper'

module Legion
  module Cache
    if Legion::Cache::Settings.normalize_driver(Legion::Settings[:cache][:driver]) == 'redis'
      extend Legion::Cache::Redis
    else
      extend Legion::Cache::Memcached
    end

    class << self
      def setup(**)
        return Legion::Settings[:cache][:connected] = true if connected?

        if ENV['LEGION_MODE'] == 'lite'
          Legion::Cache::Memory.setup
          @using_memory = true
          @connected = true
          Legion::Settings[:cache][:connected] = true
          Legion::Logging.info 'Legion::Cache using in-memory adapter (lite mode)' if defined?(Legion::Logging)
          return
        end

        setup_local
        setup_shared(**)
      end

      def shutdown
        Legion::Logging.info 'Shutting down Legion::Cache'
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

      def set(key, value, ttl = 180)
        return Legion::Cache::Memory.set(key, value, ttl) if @using_memory
        return Legion::Cache::Local.set(key, value, ttl) if @using_local

        super
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
        Legion::Logging.warn "Local cache setup failed: #{e.message}" if defined?(Legion::Logging)
      end

      def setup_shared(**)
        client(**Legion::Settings[:cache], **)
        @connected = true
        @using_local = false
        Legion::Settings[:cache][:connected] = true
        if defined?(Legion::Logging)
          driver = Legion::Settings[:cache][:driver] || 'dalli'
          servers = Array(Legion::Settings[:cache][:servers]).join(', ')
          Legion::Logging.info "Legion::Cache connected (driver=#{driver}) to #{servers}"
        end
      rescue StandardError => e
        Legion::Logging.warn "Shared cache unavailable (#{e.message}), falling back to Local" if defined?(Legion::Logging)
        if Legion::Cache::Local.connected?
          @using_local = true
          @connected = true
          Legion::Settings[:cache][:connected] = true
        else
          @connected = false
          Legion::Settings[:cache][:connected] = false
        end
      end
    end
  end
end
