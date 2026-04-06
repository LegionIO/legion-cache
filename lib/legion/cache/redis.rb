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

      def client(server: nil, servers: [], pool_size: nil, timeout: nil,
                 username: nil, password: nil, logger: nil, **opts)
        return @client unless @client.nil?

        settings = defined?(Legion::Settings) ? Legion::Settings[:cache] : {}
        pool_size ||= settings[:pool_size] || 10
        timeout ||= settings[:timeout] || 5

        cluster = opts.delete(:cluster)
        replica = opts.delete(:replica) || false
        fixed_hostname = opts.delete(:fixed_hostname)
        db = opts.delete(:db)
        reconnect_attempts = opts.delete(:reconnect_attempts) || [0, 0.5, 1]

        @pool_size = pool_size
        @timeout   = timeout
        @cluster_mode = Array(cluster).compact.any?
        @component_logger = logger || log

        @connection_opts = { username: username, password: password, timeout: @timeout }.compact
        @connection_opts.merge!(redis_tls_options(port: resolve_primary_port(server: server, servers: servers, cluster: cluster)))

        checkout_timeout = opts[:pool_checkout_timeout] || settings[:pool_checkout_timeout] || @timeout
        @client = ConnectionPool.new(size: pool_size, timeout: checkout_timeout) do
          build_redis_client(server: server, servers: servers, cluster: cluster,
                             replica: replica, fixed_hostname: fixed_hostname,
                             username: username, password: password, db: db,
                             reconnect_attempts: reconnect_attempts)
        end
        @connected = true
        log.info "Redis connected to #{resolved_redis_address(server: server, servers: servers, cluster: cluster)}"
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
          host, port = Legion::Cache::Settings.parse_server_address(resolved.first, default_port: 6379)
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
        raw = client.with { |conn| conn.get(key) }
        result = deserialize_value(raw)
        log.debug { "[cache] GET #{key} hit=#{!result.nil?}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :redis_get, key: key)
        nil
      end

      def fetch(key, ttl: nil)
        result = get(key)
        return result unless result.nil? && block_given?

        result = yield
        set(key, result, ttl: ttl)
        result
      end

      def set(key, value, ttl: nil, **)
        set_sync(key, value, ttl: ttl, **)
      end

      def set_sync(key, value, ttl: nil, **)
        effective_ttl = ttl || default_ttl
        args = {}
        args[:ex] = effective_ttl unless effective_ttl.nil?
        serialized = serialize_value(value)
        result = client.with { |conn| conn.set(key, serialized, **args) == 'OK' }
        log.debug { "[cache] SET #{key} ttl=#{effective_ttl.inspect} success=#{result}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :redis_set_sync, key: key, ttl: effective_ttl)
        raise
      end

      def delete(key, **)
        delete_sync(key)
      end

      def delete_sync(key)
        result = client.with { |conn| conn.del(key) == 1 }
        log.debug { "[cache] DELETE #{key} success=#{result}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :redis_delete_sync, key: key)
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
        log.debug { '[cache] FLUSH completed' }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :redis_flush)
        nil
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
        result = result.transform_values { |v| deserialize_value(v) }
        log.debug { "[cache] MGET keys=#{keys.size}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :redis_mget, key_count: keys.size)
        {}
      end

      def mset(hash, ttl: nil, **)
        mset_sync(hash, ttl: ttl)
      end

      def mset_sync(hash, ttl: nil, **)
        return true if hash.empty?

        hash.each { |key, value| set_sync(key, value, ttl: ttl) }
        true
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :redis_mset_sync, key_count: hash.size)
        raise
      end

      SERIALIZE_STRING = "S\x00".b.freeze
      SERIALIZE_JSON   = "J\x00".b.freeze

      private

      def serialize_value(value)
        case value
        when String
          "#{SERIALIZE_STRING}#{value}"
        else
          "#{SERIALIZE_JSON}#{Legion::JSON.dump(value)}"
        end
      end

      def deserialize_value(raw)
        return nil if raw.nil?

        raw = raw.b if raw.respond_to?(:b)
        if raw.start_with?(SERIALIZE_JSON)
          Legion::JSON.load(raw.byteslice(2..))
        elsif raw.start_with?(SERIALIZE_STRING)
          raw.byteslice(2..)
        else
          raw # legacy data, no prefix
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :redis_deserialize)
        raw
      end

      def default_ttl
        return 3600 unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :default_ttl) || 3600
      rescue StandardError
        3600
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
          host, port = Legion::Cache::Settings.parse_server_address(addr, default_port: 6379)
          node = ::Redis.new(host: host, port: port.to_i, **(@connection_opts || {}))
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

      def resolve_primary_port(server: nil, servers: [], cluster: nil)
        nodes = Array(cluster).compact
        return 6379 if nodes.any?

        resolved = Legion::Cache::Settings.resolve_servers(driver: 'redis', server: server, servers: Array(servers))
        _, port = Legion::Cache::Settings.parse_server_address(resolved.first, default_port: 6379)
        port.to_i
      rescue StandardError
        6379
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
