# frozen_string_literal: true

require 'openssl'
require 'redis'
require 'legion/logging/helper'
require 'legion/cache/pool'
require 'legion/cache/settings'

module Legion
  module Cache
    module Redis
      include Legion::Cache::Pool
      extend self
      extend Legion::Logging::Helper

      def client(pool_size: 20, timeout: 5, server: nil, servers: [], cluster: nil, replica: false, # rubocop:disable Metrics/ParameterLists
                 logger: nil,
                 fixed_hostname: nil, username: nil, password: nil, db: nil, reconnect_attempts: [0, 0.5, 1], **)
        return @client unless @client.nil?

        @pool_size = pool_size
        @timeout   = timeout
        @cluster_mode = Array(cluster).compact.any?
        @component_logger = logger || log

        @client = ConnectionPool.new(size: pool_size, timeout: timeout) do
          build_redis_client(server: server, servers: servers, cluster: cluster,
                             replica: replica, fixed_hostname: fixed_hostname,
                             username: username, password: password, db: db,
                             reconnect_attempts: reconnect_attempts)
        end
        @connected = true
        cache_logger.info "Redis connected to #{resolved_redis_address(server: server, servers: servers, cluster: cluster)}"
        @client
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :redis_client,
                            server: server, servers: Array(servers), cluster_nodes: Array(cluster))
        @connected = false
        raise
      end

      def build_redis_client(server: nil, servers: [], cluster: nil, replica: false, fixed_hostname: nil, # rubocop:disable Metrics/ParameterLists
                             username: nil, password: nil, db: nil, reconnect_attempts: [0, 0.5, 1])
        nodes = Array(cluster).compact
        if nodes.any?
          opts = { cluster: nodes, reconnect_attempts: reconnect_attempts, timeout: @timeout }
          opts[:replica] = true if replica
          opts[:fixed_hostname] = fixed_hostname unless fixed_hostname.nil?
          opts[:username] = username unless username.nil?
          opts[:password] = password unless password.nil?
          ::Redis.new(**opts)
        else
          resolved = Legion::Cache::Settings.resolve_servers(
            driver: 'redis', server: server, servers: servers
          )
          host, port = resolved.first.split(':')
          redis_opts = { host: host, port: port.to_i, reconnect_attempts: reconnect_attempts,
                         timeout: @timeout }
          redis_opts[:username] = username unless username.nil?
          redis_opts[:password] = password unless password.nil?
          redis_opts[:db] = db unless db.nil?
          redis_opts.merge!(redis_tls_options(port: port.to_i))
          ::Redis.new(**redis_opts)
        end
      end

      def cluster_mode?
        @cluster_mode == true
      end

      def get(key)
        result = client.with { |conn| conn.get(key) }
        cache_logger.debug "[cache] GET #{key} hit=#{!result.nil?}"
        result
      rescue ::Redis::BaseError => e
        log_cluster_error('redis_get', e, key: key)
        raise
      end
      alias fetch get

      def set(key, value, ttl = nil)
        args = {}
        args[:ex] = ttl unless ttl.nil?
        result = client.with { |conn| conn.set(key, value, **args) == 'OK' }
        cache_logger.debug "[cache] SET #{key} ttl=#{ttl.inspect} success=#{result}"
        result
      rescue ::Redis::BaseError => e
        log_cluster_error('redis_set', e, key: key, ttl: ttl)
        raise
      end

      def delete(key)
        result = client.with { |conn| conn.del(key) == 1 }
        cache_logger.debug "[cache] DELETE #{key} success=#{result}"
        result
      rescue ::Redis::BaseError => e
        log_cluster_error('redis_delete', e, key: key)
        raise
      end

      def flush
        result = client.with do |conn|
          if cluster_mode?
            cluster_flush(conn)
          else
            conn.flushdb == 'OK'
          end
        end
        cache_logger.debug '[cache] FLUSH completed'
        result
      rescue ::Redis::BaseError => e
        log_cluster_error('redis_flush', e)
        raise
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        result = client.with do |conn|
          if cluster_mode?
            cluster_mget(conn, keys)
          else
            values = conn.mget(*keys)
            keys.zip(values).to_h
          end
        end
        cache_logger.debug "[cache] MGET keys=#{keys.size}"
        result
      rescue ::Redis::BaseError => e
        log_cluster_error('redis_mget', e, key_count: keys.size)
        raise
      end

      def mset(hash)
        return true if hash.empty?

        result = client.with do |conn|
          if cluster_mode?
            cluster_mset(conn, hash)
          else
            conn.mset(*hash.flatten) == 'OK'
          end
        end
        cache_logger.debug "[cache] MSET keys=#{hash.size}"
        result
      rescue ::Redis::BaseError => e
        log_cluster_error('redis_mset', e, key_count: hash.size)
        raise
      end

      private

      def cache_logger
        @component_logger || log
      end

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
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cluster_flush, fallback: :single_flushdb)
        conn.flushdb == 'OK'
      end

      def group_keys_by_slot(keys)
        if defined?(::Redis::Cluster::KeySlotConverter)
          keys.group_by { |k| ::Redis::Cluster::KeySlotConverter.convert(k) }
        else
          { 0 => keys }
        end
      end

      def resolved_redis_address(server:, servers:, cluster:)
        nodes = Array(cluster).compact
        return nodes.join(', ') if nodes.any?

        Legion::Cache::Settings.resolve_servers(driver: 'redis', server: server, servers: Array(servers)).first
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :resolved_redis_address)
        'unknown'
      end

      def log_cluster_error(operation, error, **)
        handle_exception(error, level: :warn, handled: false, operation: operation, **)
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
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :cache_tls_settings)
        {}
      end
    end
  end
end
