# frozen_string_literal: true

require 'openssl'
require 'redis'
require 'legion/cache/pool'
require 'legion/cache/settings'

module Legion
  module Cache
    module Redis
      include Legion::Cache::Pool
      extend self

      def client(pool_size: 20, timeout: 5, server: nil, servers: [], cluster: nil, replica: false, fixed_hostname: nil, **) # rubocop:disable Metrics/ParameterLists
        return @client unless @client.nil?

        @pool_size = pool_size
        @timeout   = timeout
        @cluster_mode = Array(cluster).compact.any?

        @client = ConnectionPool.new(size: pool_size, timeout: timeout) do
          build_redis_client(server: server, servers: servers, cluster: cluster,
                             replica: replica, fixed_hostname: fixed_hostname)
        end
        @connected = true
        @client
      end

      def build_redis_client(server: nil, servers: [], cluster: nil, replica: false, fixed_hostname: nil)
        nodes = Array(cluster).compact
        if nodes.any?
          opts = { cluster: nodes }
          opts[:replica] = true if replica
          opts[:fixed_hostname] = fixed_hostname unless fixed_hostname.nil?
          ::Redis.new(**opts)
        else
          resolved = Legion::Cache::Settings.resolve_servers(
            driver: 'redis', server: server, servers: servers
          )
          host, port = resolved.first.split(':')
          redis_opts = { host: host, port: port.to_i }
          redis_opts.merge!(redis_tls_options(port: port.to_i))
          ::Redis.new(**redis_opts)
        end
      end

      def cluster_mode?
        @cluster_mode == true
      end

      def get(key)
        client.with { |conn| conn.get(key) }
      rescue ::Redis::BaseError => e
        log_cluster_error(e)
        raise
      end
      alias fetch get

      def set(key, value, ttl: nil)
        args = {}
        args[:ex] = ttl unless ttl.nil?
        client.with { |conn| conn.set(key, value, **args) == 'OK' }
      rescue ::Redis::BaseError => e
        log_cluster_error(e)
        raise
      end

      def delete(key)
        client.with { |conn| conn.del(key) == 1 }
      rescue ::Redis::BaseError => e
        log_cluster_error(e)
        raise
      end

      def flush
        client.with do |conn|
          if cluster_mode?
            cluster_flush(conn)
          else
            conn.flushdb == 'OK'
          end
        end
      rescue ::Redis::BaseError => e
        log_cluster_error(e)
        raise
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        client.with do |conn|
          if cluster_mode?
            cluster_mget(conn, keys)
          else
            result = conn.mget(*keys)
            keys.zip(result).to_h
          end
        end
      rescue ::Redis::BaseError => e
        log_cluster_error(e)
        raise
      end

      def mset(hash)
        return true if hash.empty?

        client.with do |conn|
          if cluster_mode?
            cluster_mset(conn, hash)
          else
            conn.mset(*hash.flatten) == 'OK'
          end
        end
      rescue ::Redis::BaseError => e
        log_cluster_error(e)
        raise
      end

      private

      def cluster_mget(conn, keys)
        groups = group_keys_by_slot(keys)
        result = {}
        groups.each_value do |group_keys|
          values = conn.mget(*group_keys)
          group_keys.zip(values).each { |k, v| result[k] = v }
        end
        result
      end

      def cluster_mset(conn, hash)
        groups = group_keys_by_slot(hash.keys)
        groups.each_value do |group_keys|
          pairs = group_keys.flat_map { |k| [k, hash[k]] }
          conn.mset(*pairs)
        end
        true
      end

      def cluster_flush(conn)
        node_info = conn.cluster('nodes')
        primaries = node_info.lines.select { |l| l.include?('master') }.map { |l| l.split[1].split('@').first }
        primaries.each do |addr|
          host, port = addr.split(':')
          node = ::Redis.new(host: host, port: port.to_i)
          node.flushdb
          node.close
        end
        true
      rescue StandardError
        conn.flushdb == 'OK'
      end

      def group_keys_by_slot(keys)
        if defined?(::Redis::Cluster::KeySlotConverter)
          keys.group_by { |k| ::Redis::Cluster::KeySlotConverter.convert(k) }
        else
          { 0 => keys }
        end
      end

      def log_cluster_error(error)
        return unless defined?(Legion::Logging)

        Legion::Logging.warn "Redis cluster error: #{error.class} — #{error.message}"
      end

      def redis_tls_options(port:)
        return {} unless defined?(Legion::Crypt::TLS)

        tls = Legion::Crypt::TLS.resolve(cache_tls_settings, port: port)
        return {} unless tls[:enabled]

        ssl_params = {
          verify_mode: tls[:verify] == :none ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
        }
        ssl_params[:ca_file] = tls[:ca] if tls[:ca]

        { ssl: true, ssl_params: ssl_params }
      end

      def cache_tls_settings
        return {} unless defined?(Legion::Settings)

        Legion::Settings[:cache][:tls] || {}
      rescue StandardError
        {}
      end
    end
  end
end
