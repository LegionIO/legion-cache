# frozen_string_literal: true

require 'digest'

module Legion
  module Cache
    module Cacheable
      def self.extended(base)
        base.instance_variable_set(:@_cached_methods, {})
      end

      def cached_methods
        @_cached_methods ||= {}
      end

      def cache_method(method_name, ttl:, scope: :local, exclude_from_key: [])
        exclude_from_key |= %i[token bypass_local_method_cache]
        cached_methods[method_name] = { ttl: ttl, scope: scope, exclude_from_key: exclude_from_key }

        mod_name = name || 'Anonymous'
        config = cached_methods[method_name]

        wrapper = Module.new do
          define_method(method_name) do |bypass_local_method_cache: false, **kwargs|
            key = Legion::Cache::Cacheable.build_cache_key(
              mod_name, method_name, exclude: config[:exclude_from_key], **kwargs
            )

            unless bypass_local_method_cache
              cached = Legion::Cache::Cacheable.cache_read(key, scope: config[:scope])
              return cached unless cached.nil?
            end

            result = super(**kwargs)
            Legion::Cache::Cacheable.cache_write(key, result, ttl: config[:ttl], scope: config[:scope])
            result
          end
        end

        prepend wrapper
      end

      def self.build_cache_key(mod_name, method_name, exclude:, **kwargs)
        filtered = kwargs.reject { |k, _| exclude.include?(k) }
        args_hash = Digest::MD5.hexdigest(filtered.sort.to_s)
        "#{mod_name}.#{method_name}.#{args_hash}"
      end

      def self.cache_read(key, scope:)
        case scope
        when :global
          return Legion::Cache.get(key) if global_cache_available?

          memory_read(key)
        else
          local_cache_read(key) || memory_read(key)
        end
      end

      def self.cache_write(key, value, ttl:, scope:)
        case scope
        when :global
          if global_cache_available?
            Legion::Cache.set(key, value, ttl)
          else
            memory_write(key, value, ttl)
          end
        else
          if local_cache_available?
            local_cache_write(key, value, ttl)
          else
            memory_write(key, value, ttl)
          end
        end
      end

      def self.global_cache_available?
        defined?(Legion::Cache) && Legion::Cache.respond_to?(:connected?) && Legion::Cache.connected?
      end

      def self.local_cache_available?
        defined?(Legion::Cache::Local) && Legion::Cache::Local.respond_to?(:connected?) && Legion::Cache::Local.connected?
      end

      def self.local_cache_read(key)
        return nil unless local_cache_available?

        Legion::Cache::Local.get(key)
      rescue StandardError
        nil
      end

      def self.local_cache_write(key, value, ttl)
        return unless local_cache_available?

        Legion::Cache::Local.set(key, value, ttl)
      rescue StandardError
        nil
      end

      # In-memory fallback store (class-level, process-wide)
      def self.memory_store
        @memory_store ||= {}
      end

      def self.memory_read(key)
        entry = memory_store[key]
        return nil unless entry
        return nil if Time.now.utc > entry[:expires_at]

        entry[:value]
      end

      def self.memory_write(key, value, ttl)
        memory_store[key] = { value: value, expires_at: Time.now.utc + ttl }
      end

      def self.memory_clear!
        @memory_store = {}
      end
    end
  end
end
