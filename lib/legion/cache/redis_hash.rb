# frozen_string_literal: true

module Legion
  module Cache
    module RedisHash
      module_function

      # Returns true when the Redis driver is loaded and the connection pool is live.
      def redis_available?
        pool = Legion::Cache.instance_variable_get(:@client)
        return false if pool.nil?

        Legion::Cache.connected?
      rescue StandardError
        false
      end

      # Set hash fields from a Ruby Hash.
      # Uses Redis HSET key field value [field value ...]
      def hset(key, hash)
        return false unless redis_available?

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          flat = hash.flat_map { |k, v| [k.to_s, v.to_s] }
          conn.hset(key, *flat)
        end
        true
      rescue StandardError => e
        log_redis_error('hset', e)
        false
      end

      # Returns a Ruby Hash (string keys) of all field-value pairs for the key.
      def hgetall(key)
        return nil unless redis_available?

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          conn.hgetall(key)
        end
      rescue StandardError => e
        log_redis_error('hgetall', e)
        nil
      end

      # Delete one or more hash fields.
      def hdel(key, *fields)
        return 0 unless redis_available?

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          conn.hdel(key, *fields)
        end
      rescue StandardError => e
        log_redis_error('hdel', e)
        0
      end

      # Add a member to a sorted set with the given score.
      def zadd(key, score, member)
        return false unless redis_available?

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          conn.zadd(key, score.to_f, member.to_s)
        end
        true
      rescue StandardError => e
        log_redis_error('zadd', e)
        false
      end

      # Range query on a sorted set by score. Returns an array of members.
      # limit: accepts [offset, count] array matching Redis LIMIT semantics.
      def zrangebyscore(key, min, max, limit: nil)
        return [] unless redis_available?

        opts = {}
        opts[:limit] = limit if limit

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          conn.zrangebyscore(key, min, max, **opts)
        end
      rescue StandardError => e
        log_redis_error('zrangebyscore', e)
        []
      end

      # Remove a member from a sorted set.
      def zrem(key, member)
        return false unless redis_available?

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          conn.zrem(key, member.to_s)
        end
        true
      rescue StandardError => e
        log_redis_error('zrem', e)
        false
      end

      # Set a TTL (in seconds) on a key.
      def expire(key, seconds)
        return false unless redis_available?

        Legion::Cache.instance_variable_get(:@client).with do |conn|
          conn.expire(key, seconds.to_i) == 1
        end
      rescue StandardError => e
        log_redis_error('expire', e)
        false
      end

      def log_redis_error(method, error)
        return unless defined?(Legion::Logging)

        Legion::Logging.warn "[cache:redis_hash] #{method} failed: #{error.class} — #{error.message}"
      end
    end
  end
end
