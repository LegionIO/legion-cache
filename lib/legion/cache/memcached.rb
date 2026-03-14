# frozen_string_literal: true

require 'dalli'
require 'legion/cache/pool'

module Legion
  module Cache
    module Memcached
      include Legion::Cache::Pool
      extend self # rubocop:disable Style/ModuleFunction

      def client(servers: Legion::Settings[:cache][:servers], **opts)
        return @client unless @client.nil?

        @pool_size = opts.key?(:pool_size) ? opts[:pool_size] : Legion::Settings[:cache][:pool_size] || 10
        @timeout = opts.key?(:timeout) ? opts[:timeout] : Legion::Settings[:cache][:timeout] || 5

        Dalli.logger = Legion::Logging
        @client = ConnectionPool.new(size: pool_size, timeout: timeout) do
          Dalli::Client.new(servers, Legion::Settings[:cache].merge(opts))
        end

        @connected = true
        @client
      end

      def get(key)
        result = client.with { |conn| conn.get(key) }
        Legion::Logging.debug "[cache] GET #{key} hit=#{!result.nil?}"
        result
      end

      def fetch(key, ttl = nil)
        result = client.with { |conn| conn.fetch(key, ttl) }
        Legion::Logging.debug "[cache] FETCH #{key} hit=#{!result.nil?}"
        result
      end

      def set(key, value, ttl = 180)
        result = client.with { |conn| conn.set(key, value, ttl).positive? }
        Legion::Logging.debug "[cache] SET #{key} ttl=#{ttl} success=#{result} value_class=#{value.class}"
        result
      end

      def delete(key)
        result = client.with { |conn| conn.delete(key) == true }
        Legion::Logging.debug "[cache] DELETE #{key} success=#{result}"
        result
      end

      def flush(delay = 0)
        client.with { |conn| conn.flush(delay).first }
      end
    end
  end
end
