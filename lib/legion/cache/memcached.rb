# frozen_string_literal: true

require 'openssl'
require 'dalli'
require 'legion/logging/helper'
require 'legion/cache/pool'

module Legion
  module Cache
    module Memcached
      include Legion::Cache::Pool
      extend self
      extend Legion::Logging::Helper

      def client(server: nil, servers: nil, pool_size: nil, timeout: nil, # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/ParameterLists
                 username: nil, password: nil, logger: nil, **opts)
        return @client unless @client.nil?

        settings = defined?(Legion::Settings) ? Legion::Settings[:cache] : {}
        servers ||= settings[:servers] || []
        @component_logger = logger || log

        @pool_size = pool_size || settings[:pool_size] || 10
        @timeout = timeout || settings[:timeout] || 5

        resolved = Legion::Cache::Settings.resolve_servers(
          driver: 'memcached', server: server, servers: Array(servers)
        )

        Dalli.logger = log
        cache_opts = settings.merge(opts)
        cache_opts[:value_max_bytes] ||= 8 * 1024 * 1024
        cache_opts[:serializer] ||= Legion::JSON
        cache_opts[:username] = username unless username.nil?
        cache_opts[:password] = password unless password.nil?

        tls_ctx = memcached_tls_context(port: resolved.first.split(':').last.to_i)
        cache_opts[:ssl_context] = tls_ctx if tls_ctx

        checkout_timeout = opts[:pool_checkout_timeout] || settings[:pool_checkout_timeout] || @timeout
        @client = ConnectionPool.new(size: @pool_size, timeout: checkout_timeout) do
          Dalli::Client.new(resolved, cache_opts)
        end

        @connected = true
        log.info "Memcached connected to #{resolved.join(', ')}"
        @client
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memcached_client,
                            server: server, servers: Array(servers))
        @connected = false
        raise
      end

      def get(key)
        result = client.with { |conn| conn.get(key) }
        log.debug { "[cache] GET #{key} hit=#{!result.nil?}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memcached_get, key: key)
        nil
      end

      def fetch(key, ttl: nil, &)
        result = client.with do |conn|
          if block_given?
            conn.fetch(key, ttl, &)
          else
            conn.fetch(key, ttl)
          end
        end
        log.debug { "[cache] FETCH #{key} hit=#{!result.nil?}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memcached_fetch, key: key, ttl: ttl)
        nil
      end

      def set(key, value, ttl: nil, **)
        set_sync(key, value, ttl: ttl, **)
      end

      def set_sync(key, value, ttl: nil, **)
        effective_ttl = ttl || default_ttl
        result = client.with { |conn| conn.set(key, value, effective_ttl).positive? }
        log.debug { "[cache] SET #{key} ttl=#{effective_ttl} success=#{result} value_class=#{value.class}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memcached_set_sync, key: key, ttl: effective_ttl)
        raise
      end

      def delete(key, **)
        delete_sync(key)
      end

      def delete_sync(key)
        result = client.with { |conn| conn.delete(key) == true }
        log.debug { "[cache] DELETE #{key} success=#{result}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memcached_delete_sync, key: key)
        raise
      end

      def flush
        result = client.with { |conn| conn.flush.first }
        log.debug { '[cache] FLUSH completed' }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memcached_flush)
        nil
      end

      def mget(*keys)
        keys = keys.flatten
        return {} if keys.empty?

        result = client.with { |conn| conn.get_multi(*keys) }
        log.debug { "[cache] MGET keys=#{keys.size} hits=#{result.size}" }
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memcached_mget, key_count: keys.size)
        {}
      end

      def mset(hash, ttl: nil, **)
        mset_sync(hash, ttl: ttl)
      end

      def mset_sync(hash, ttl: nil, **) # rubocop:disable Lint/UnusedMethodArgument
        return true if hash.empty?

        client.with { |conn| conn.set_multi(hash) }
        log.debug { "[cache] MSET keys=#{hash.size}" }
        true
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memcached_mset_sync, key_count: hash.size)
        raise
      end

      private

      def default_ttl
        return 3600 unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :default_ttl) || 3600
      rescue StandardError
        3600
      end

      def memcached_tls_context(port:)
        return nil unless defined?(Legion::Crypt::TLS)

        tls = Legion::Crypt::TLS.resolve(memcached_tls_settings, port: port)
        return nil unless tls[:enabled]

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = tls[:verify] == :none ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
        ctx.ca_file     = tls[:ca] if tls[:ca]
        ctx
      end

      def memcached_tls_settings
        return {} unless defined?(Legion::Settings)

        Legion::Settings[:cache][:tls] || {}
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :memcached_tls_settings)
        {}
      end
    end
  end
end
