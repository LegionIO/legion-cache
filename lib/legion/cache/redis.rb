# frozen_string_literal: true

require 'openssl'
require 'redis'
require 'uri'
require 'legion/logging/helper'
require 'legion/cache/pool'
require 'legion/cache/settings'

module Legion
  module Cache
    module Redis
      include Legion::Cache::Pool
      extend self
      extend Legion::Logging::Helper

      def client(**opts)
        return @client unless @client.nil?

        settings = redis_settings.merge(opts)
        if opts.key?(:server) || opts.key?(:servers)
          settings[:server] = opts[:server]
          settings[:servers] = opts.fetch(:servers, [])
          settings[:cluster] = nil unless opts.key?(:cluster)
        end
        @redis_settings = settings
        @pool_size = settings[:pool_size] || 10
        @timeout = settings[:timeout] || 5
        raise ArgumentError, 'Redis timeout must be positive' unless @timeout.positive?

        @cluster_mode = Array(settings[:cluster]).compact.any?
        @component_logger = settings[:logger] || log
        checkout_timeout = settings[:pool_checkout_timeout] || @timeout
        pending_pool = ConnectionPool.new(size: @pool_size, timeout: checkout_timeout) do
          build_redis_client(**settings.slice(:server, :servers, :cluster, :replica, :fixed_hostname,
                                              :username, :password, :db, :reconnect_attempts))
        end
        pending_pool.with do |conn|
          raise ::Redis::ConnectionError, 'Redis health check failed' unless conn.ping == 'PONG'
        end
        @client = pending_pool
        cache_mark_connected(true)
        @client
      rescue StandardError => e
        cache_mark_connected(false)
        @client = nil
        begin
          pending_pool&.shutdown(&:close)
        rescue StandardError => close_error
          handle_exception(close_error, level: :warn, handled: true, operation: :redis_failed_pool_close)
        end
        handle_exception(e, level: :error, handled: false, operation: :redis_client)
        raise
      end

      def build_redis_client(server: nil, servers: [], cluster: nil, replica: false, fixed_hostname: nil, # rubocop:disable Metrics/ParameterLists
                             username: nil, password: nil, db: nil, reconnect_attempts: [0, 0.5, 1])
        nodes = Array(cluster).compact
        options = { username: username, password: password, db: db, timeout: @timeout || 5,
                    reconnect_attempts: reconnect_attempts }.compact
        if nodes.any?
          require 'redis-clustering'
          raise ArgumentError, 'Redis Cluster only supports database 0' unless db.nil? || db.to_i.zero?

          options.merge!(redis_tls_options(port: resolve_primary_port(cluster: nodes)))
          options[:replica] = replica
          options[:fixed_hostname] = fixed_hostname unless fixed_hostname.nil?
          ::Redis::Cluster.new(nodes: nodes, **options)
        else
          address = (Array(servers) + Array(server)).first
          if address.to_s.start_with?('redis://', 'rediss://')
            options[:url] = address
            port = URI.parse(address).port || 6379
          else
            host, port = Legion::Cache::Settings.parse_server_address(address, default_port: 6379)
            options.merge!(host: host, port: port)
          end
          options.merge!(redis_tls_options(port: port))
          ::Redis.new(**options)
        end
      end

      def cluster_mode?
        @cluster_mode == true
      end

      def redis_key(key)
        namespace = redis_settings[:namespace].to_s
        namespace.empty? ? key.to_s : "#{namespace}:#{key}"
      end

      def get(key)
        raw = client.with { |conn| conn.get(redis_key(key)) }
        result = deserialize_value(raw)
        log.debug { "[cache] GET #{key} hit=#{!result.nil?}" }
        result
      rescue StandardError => e
        cache_backend_failed(e)
        handle_exception(e, level: :warn, handled: true, operation: :redis_get, key: key)
        nil
      end

      def fetch(key, ttl: nil)
        redis_ttl(ttl)
        result = get(key)
        return result unless result.nil? && block_given?

        result = yield
        begin
          set(key, result, ttl: ttl)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :redis_fetch_store, key: key)
        end
        result
      end

      def set_nx(key, value, ttl: nil)
        effective_ttl = redis_ttl(ttl)
        serialized = serialize_value(value)
        args = effective_ttl ? { ex: effective_ttl } : {}
        result = client.with { |conn| conn.set(redis_key(key), serialized, nx: true, **args) == 'OK' }
        log.debug { "[cache] SET_NX #{key} ttl=#{effective_ttl.inspect} result=#{result}" }
        result
      rescue StandardError => e
        cache_backend_failed(e)
        handle_exception(e, level: :error, handled: false, operation: :redis_set_nx, key: key, ttl: effective_ttl)
        raise
      end

      def set(key, value, ttl: nil, **)
        set_sync(key, value, ttl: ttl, **)
      end

      def set_sync(key, value, ttl: nil, **)
        effective_ttl = redis_ttl(ttl)
        args = {}
        args[:ex] = effective_ttl unless effective_ttl.nil?
        serialized = serialize_value(value)
        result = client.with { |conn| conn.set(redis_key(key), serialized, **args) == 'OK' }
        log.debug { "[cache] SET #{key} ttl=#{effective_ttl.inspect} success=#{result}" }
        result
      rescue StandardError => e
        cache_backend_failed(e)
        handle_exception(e, level: :error, handled: false, operation: :redis_set_sync, key: key, ttl: effective_ttl)
        raise
      end

      def cas(key, ttl: nil)
        effective_ttl = redis_ttl(ttl)
        args = effective_ttl ? { ex: effective_ttl } : {}
        qualified = redis_key(key)
        user_error = nil
        client.with do |conn|
          10.times do
            value = nil
            committed = conn.watch(qualified) do |watched|
              current = deserialize_value(watched.get(qualified))
              begin
                value = yield current
              rescue StandardError => e
                user_error = e
                raise
              end
              serialized = serialize_value(value)
              watched.multi { |transaction| transaction.set(qualified, serialized, **args) }
            end
            return value unless committed.nil?
          end
          raise ::Redis::CommandError, 'Redis CAS conflicted after 10 attempts'
        end
      rescue StandardError => e
        raise if e.equal?(user_error)

        cache_backend_failed(e)
        handle_exception(e, level: :error, handled: false, operation: :redis_cas, key: key)
        raise
      end

      def delete(key, **)
        delete_sync(key)
      end

      def delete_sync(key)
        result = client.with { |conn| conn.del(redis_key(key)) == 1 }
        log.debug { "[cache] DELETE #{key} success=#{result}" }
        result
      rescue StandardError => e
        cache_backend_failed(e)
        handle_exception(e, level: :error, handled: false, operation: :redis_delete_sync, key: key)
        raise
      end

      def flush
        result = client.with do |conn|
          prefix = redis_key('')
          raise ArgumentError, 'Redis flush requires a namespace' if prefix.empty?

          pattern = prefix.gsub(/[\\*?\[\]]/) { |character| "\\#{character}" }
          conn.scan_each(match: "#{pattern}*", count: 100) { |key| conn.del(key) }
          true
        end
        log.debug { '[cache] FLUSH completed' }
        result
      rescue StandardError => e
        cache_backend_failed(e)
        handle_exception(e, level: :warn, handled: true, operation: :redis_flush)
        nil
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        qualified = keys.map { |key| redis_key(key) }
        values = client.with do |conn|
          if cluster_mode?
            cluster_mget(conn, qualified).values_at(*qualified)
          else
            conn.mget(*qualified)
          end
        end
        result = keys.zip(values.map { |value| deserialize_value(value) }).to_h
        log.debug { "[cache] MGET keys=#{keys.size}" }
        result
      rescue StandardError => e
        cache_backend_failed(e)
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

      def redis_settings
        return @redis_settings if @redis_settings
        return @cache_settings if @cache_settings

        shared = defined?(Legion::Settings) ? Legion::Settings[:cache] : nil
        Legion::Cache::Settings.default.merge(shared || {})
      end

      def default_ttl
        redis_settings[:default_ttl]
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

      def group_keys_by_slot(keys)
        keys.group_by { |key| ::RedisClient::Cluster::KeySlotConverter.convert(key) }
      end

      def redis_ttl(ttl)
        value = ttl.nil? ? default_ttl : ttl
        return nil if value.nil?

        raise ArgumentError, 'TTL must not be negative' if value.negative?

        value.zero? ? nil : value
      end

      def resolve_primary_port(server: nil, servers: [], cluster: nil)
        address = Array(cluster).compact.first || (Array(servers) + Array(server)).first
        return address.fetch(:port, 6379).to_i if address.is_a?(Hash)
        return URI.parse(address).port || 6379 if address.to_s.start_with?('redis://', 'rediss://')

        Legion::Cache::Settings.parse_server_address(address, default_port: 6379).last
      end

      def redis_tls_options(port:)
        unless defined?(Legion::Crypt::TLS)
          settings = cache_tls_settings
          return {} if settings.empty? || settings[:enabled] == false

          raise ArgumentError, 'Legion::Crypt::TLS is required for configured Redis TLS'
        end

        tls = Legion::Crypt::TLS.resolve(cache_tls_settings, port: port)
        return {} unless tls[:enabled]

        ssl_params = {
          verify_mode: tls[:verify] == :none ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
        }
        ssl_params[:ca_file] = tls[:ca] if tls[:ca]
        ssl_params[:cert] = OpenSSL::X509::Certificate.new(File.read(tls[:cert])) if tls[:cert]
        ssl_params[:key] = OpenSSL::PKey.read(File.read(tls[:key])) if tls[:key]

        { ssl: true, ssl_params: ssl_params }
      end

      def cache_tls_settings
        redis_settings[:tls] || {}
      end
    end
  end
end
