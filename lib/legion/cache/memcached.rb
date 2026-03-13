# frozen_string_literal: true

require 'dalli'
require 'legion/cache/pool'

module Legion
  module Cache
    module Memcached
      include Legion::Cache::Pool

      module_function

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
        client.with { |conn| conn.get(key) }
      end

      def fetch(key, ttl = nil)
        client.with { |conn| conn.fetch(key, ttl) }
      end

      def set(key, value, ttl = 180)
        client.with { |conn| conn.set(key, value, ttl).positive? }
      end

      def delete(key)
        client.with { |conn| conn.delete(key) == true }
      end

      def flush(delay = 0)
        client.with { |conn| conn.flush(delay).first }
      end
    end
  end
end
