# frozen_string_literal: true

require 'redis'
require 'legion/cache/pool'
require 'legion/cache/settings'

module Legion
  module Cache
    module Redis
      include Legion::Cache::Pool
      extend self # rubocop:disable Style/ModuleFunction

      def client(pool_size: 20, timeout: 5, server: nil, servers: [], **)
        return @client unless @client.nil?

        @pool_size = pool_size
        @timeout = timeout

        resolved = Legion::Cache::Settings.resolve_servers(
          driver: 'redis', server: server, servers: servers
        )
        host, port = resolved.first.split(':')

        @client = ConnectionPool.new(size: pool_size, timeout: timeout) do
          ::Redis.new(host: host, port: port.to_i)
        end
        @connected = true
        @client
      end

      def get(key)
        client.with { |conn| conn.get(key) }
      end
      alias fetch get

      def set(key, value, ttl: nil)
        args = {}
        args[:ex] = ttl unless ttl.nil?
        client.with { |conn| conn.set(key, value, **args) == 'OK' }
      end

      def delete(key)
        client.with { |conn| conn.del(key) == 1 }
      end

      def flush
        client.with { |conn| conn.flushdb == 'OK' }
      end
    end
  end
end
