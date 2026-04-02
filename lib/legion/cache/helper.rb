# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Cache
    module Helper
      include Legion::Logging::Helper

      FALLBACK_TTL = 60

      # --- TTL Resolution ---
      # Override in your LEX to set a custom default TTL for the extension.
      # Resolution chain: per-call ttl: kwarg -> LEX override -> Settings -> FALLBACK_TTL
      def cache_default_ttl
        return FALLBACK_TTL unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :default_ttl) || FALLBACK_TTL
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_default_ttl)
        FALLBACK_TTL
      end

      def local_cache_default_ttl
        return cache_default_ttl unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache_local, :default_ttl) || cache_default_ttl
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :local_cache_default_ttl)
        cache_default_ttl
      end

      # --- Namespace ---

      def cache_namespace
        @cache_namespace ||= derive_cache_namespace
      end

      # --- Core Operations (shared tier) ---

      def cache_set(key, value, ttl: nil, phi: false)
        effective_ttl = ttl || cache_default_ttl
        Legion::Cache.set(cache_namespace + key, value, effective_ttl, phi: phi)
      end

      def cache_get(key)
        Legion::Cache.get(cache_namespace + key)
      end

      def cache_delete(key)
        Legion::Cache.delete(cache_namespace + key)
      end

      def cache_fetch(key, ttl: nil, &)
        effective_ttl = ttl || cache_default_ttl
        Legion::Cache.fetch(cache_namespace + key, effective_ttl, &)
      end

      def cache_exist?(key)
        !Legion::Cache.get(cache_namespace + key).nil?
      end

      # --- Batch Operations (shared tier) ---
      # Issue #3: mget/mset with Memcached safety

      # Returns a Hash of { key => value } pairs. Prefixes all keys with cache_namespace.
      # Delegates to Legion::Cache.mget on Redis; falls back to sequential gets on Memcached.
      def cache_mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        namespaced = keys.map { |k| cache_namespace + k }

        if cache_redis?
          raw = Legion::Cache.mget(*namespaced)
          keys.to_h { |k| [k, raw[cache_namespace + k]] }
        else
          keys.to_h { |k| [k, Legion::Cache.get(cache_namespace + k)] }
        end
      rescue StandardError => e
        log_cache_error('cache_mget', e)
        {}
      end

      # Stores multiple key-value pairs. Accepts a Hash of { key => value }.
      # TTL follows the same resolution chain as cache_set.
      # Delegates to Legion::Cache.mset on Redis; falls back to sequential sets on Memcached.
      def cache_mset(hash, ttl: nil)
        return true if hash.empty?

        effective_ttl = ttl || cache_default_ttl

        hash.each { |k, v| Legion::Cache.set(cache_namespace + k, v, effective_ttl) }
        true
      rescue StandardError => e
        log_cache_error('cache_mset', e)
        false
      end

      # --- Batch Operations (local tier) ---

      def local_cache_mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        keys.to_h { |k| [k, Legion::Cache::Local.get(cache_namespace + k)] }
      rescue StandardError => e
        log_cache_error('local_cache_mget', e)
        {}
      end

      def local_cache_mset(hash, ttl: nil)
        return true if hash.empty?

        effective_ttl = ttl || local_cache_default_ttl

        hash.each { |k, v| Legion::Cache::Local.set(cache_namespace + k, v, effective_ttl) }
        true
      rescue StandardError => e
        log_cache_error('local_cache_mset', e)
        false
      end

      # --- RedisHash Helpers (shared tier) ---
      # Issue #4: namespaced wrappers for RedisHash operations with Memcached fallback

      def cache_hset(key, hash)
        if cache_redis?
          Legion::Cache::RedisHash.hset(cache_namespace + key, hash)
        else
          memcached_hash_merge(cache_namespace + key, hash)
        end
      rescue StandardError => e
        log_cache_error('cache_hset', e)
        false
      end

      def cache_hgetall(key)
        if cache_redis?
          Legion::Cache::RedisHash.hgetall(cache_namespace + key)
        else
          memcached_hash_load(cache_namespace + key)
        end
      rescue StandardError => e
        log_cache_error('cache_hgetall', e)
        nil
      end

      def cache_hdel(key, *fields)
        if cache_redis?
          Legion::Cache::RedisHash.hdel(cache_namespace + key, *fields)
        else
          memcached_hash_delete_fields(cache_namespace + key, fields)
        end
      rescue StandardError => e
        log_cache_error('cache_hdel', e)
        0
      end

      def cache_zadd(key, score, member)
        raise_sorted_set_unsupported('cache_zadd') unless cache_redis?

        Legion::Cache::RedisHash.zadd(cache_namespace + key, score, member)
      rescue NotImplementedError
        raise
      rescue StandardError => e
        log_cache_error('cache_zadd', e)
        false
      end

      def cache_zrangebyscore(key, min, max, limit: nil)
        raise_sorted_set_unsupported('cache_zrangebyscore') unless cache_redis?

        Legion::Cache::RedisHash.zrangebyscore(cache_namespace + key, min, max, limit: limit)
      rescue NotImplementedError
        raise
      rescue StandardError => e
        log_cache_error('cache_zrangebyscore', e)
        []
      end

      def cache_zrem(key, member)
        raise_sorted_set_unsupported('cache_zrem') unless cache_redis?

        Legion::Cache::RedisHash.zrem(cache_namespace + key, member)
      rescue NotImplementedError
        raise
      rescue StandardError => e
        log_cache_error('cache_zrem', e)
        false
      end

      # Sets TTL on a key. No-op on Memcached (TTL is set at write time).
      def cache_expire(key, seconds)
        return false unless cache_redis?

        Legion::Cache::RedisHash.expire(cache_namespace + key, seconds)
      rescue StandardError => e
        log_cache_error('cache_expire', e)
        false
      end

      # --- Core Operations (local tier) ---

      def local_cache_set(key, value, ttl: nil, phi: false)
        effective_ttl = ttl || local_cache_default_ttl
        effective_ttl = Legion::Cache.enforce_phi_ttl(effective_ttl, phi: phi)
        Legion::Cache::Local.set(cache_namespace + key, value, effective_ttl)
      end

      def local_cache_get(key)
        Legion::Cache::Local.get(cache_namespace + key)
      end

      def local_cache_delete(key)
        Legion::Cache::Local.delete(cache_namespace + key)
      end

      def local_cache_fetch(key, ttl: nil, &)
        effective_ttl = ttl || local_cache_default_ttl
        Legion::Cache::Local.fetch(cache_namespace + key, effective_ttl, &)
      end

      def local_cache_exist?(key)
        !Legion::Cache::Local.get(cache_namespace + key).nil?
      end

      # --- Status ---

      def cache_connected?
        Legion::Cache.connected?
      end

      def local_cache_connected?
        Legion::Cache::Local.connected?
      end

      # --- Pool Info ---

      def cache_pool_size
        return 0 unless cache_connected?

        Legion::Cache.pool_size
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_pool_size)
        0
      end

      def cache_pool_available
        return 0 unless cache_connected?

        Legion::Cache.available
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_pool_available)
        0
      end

      def local_cache_pool_size
        return 0 unless local_cache_connected?

        Legion::Cache::Local.pool_size
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :local_cache_pool_size)
        0
      end

      def local_cache_pool_available
        return 0 unless local_cache_connected?

        Legion::Cache::Local.available
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :local_cache_pool_available)
        0
      end

      private

      def derive_cache_namespace
        if respond_to?(:lex_filename)
          fname = lex_filename
          fname.is_a?(Array) ? fname.first : fname
        else
          derive_cache_namespace_from_class
        end
      end

      def derive_cache_namespace_from_class
        name = respond_to?(:ancestors) ? ancestors.first.to_s : self.class.to_s
        parts = name.split('::')
        ext_idx = parts.index('Extensions')
        target = if ext_idx && parts[ext_idx + 1]
                   parts[ext_idx + 1]
                 else
                   parts.last
                 end
        target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
      end

      def cache_redis?
        Legion::Cache::RedisHash.redis_available?
      end

      def local_cache_redis?
        defined?(Legion::Cache::Local) &&
          Legion::Cache::Local.connected? &&
          Legion::Cache::Local.respond_to?(:driver_name) &&
          Legion::Cache::Local.driver_name == 'redis'
      end

      def memcached_hash_merge(full_key, new_fields)
        current = memcached_hash_load(full_key) || {}
        merged = current.merge(new_fields.transform_keys(&:to_s))
        Legion::Cache.set(full_key, Legion::JSON.dump(merged), cache_default_ttl)
        true
      end

      def memcached_hash_load(full_key)
        raw = Legion::Cache.get(full_key)
        return nil if raw.nil?

        parsed = Legion::JSON.load(raw)
        # Legion::JSON.load returns symbol keys; convert to string keys to mirror Redis hgetall
        parsed.transform_keys(&:to_s)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memcached_hash_load, key: full_key)
        nil
      end

      def memcached_hash_delete_fields(full_key, fields)
        current = memcached_hash_load(full_key)
        return 0 if current.nil?

        str_fields = fields.map(&:to_s)
        removed = str_fields.count { |f| current.key?(f) }
        str_fields.each { |f| current.delete(f) }
        Legion::Cache.set(full_key, Legion::JSON.dump(current), cache_default_ttl)
        removed
      end

      def raise_sorted_set_unsupported(method)
        raise NotImplementedError,
              "#{method} requires a Redis backend — sorted sets are not supported on Memcached"
      end

      def log_cache_error(method, error)
        handle_exception(error, level: :warn, operation: method)
      end
    end
  end
end
