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

      def client(server: nil, servers: nil, logger: nil, **opts)
        return @client unless @client.nil?

        settings = defined?(Legion::Settings) ? Legion::Settings[:cache] : {}
        servers ||= settings[:servers] || []
        @component_logger = logger || log

        @pool_size = opts.key?(:pool_size) ? opts[:pool_size] : settings[:pool_size] || 10
        @timeout = opts.key?(:timeout) ? opts[:timeout] : settings[:timeout] || 5

        resolved = Legion::Cache::Settings.resolve_servers(
          driver: 'memcached', server: server, servers: Array(servers)
        )

        Dalli.logger = shared_dalli_logger
        cache_opts = settings.merge(opts)
        cache_opts[:value_max_bytes] ||= 8 * 1024 * 1024
        cache_opts[:serializer] ||= Legion::JSON

        tls_ctx = memcached_tls_context(port: resolved.first.split(':').last.to_i)
        cache_opts[:ssl_context] = tls_ctx if tls_ctx

        @client = ConnectionPool.new(size: pool_size, timeout: timeout) do
          Dalli::Client.new(resolved, cache_opts)
        end

        @connected = true
        cache_logger.info "Memcached connected to #{resolved.join(', ')}"
        @client
      rescue StandardError => e
        handle_exception(e, level: :error, handled: false, operation: :memcached_client,
                            server: server, servers: Array(servers))
        @connected = false
        raise
      end

      def get(key)
        result = client.with { |conn| conn.get(key) }
        cache_logger.debug "[cache] GET #{key} hit=#{!result.nil?}"
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: :memcached_get, key: key)
        raise
      end

      def fetch(key, ttl = nil, &)
        result = client.with do |conn|
          if block_given?
            conn.fetch(key, ttl, &)
          else
            conn.fetch(key, ttl)
          end
        end
        cache_logger.debug "[cache] FETCH #{key} hit=#{!result.nil?}"
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: :memcached_fetch, key: key, ttl: ttl)
        raise
      end

      def set(key, value, ttl = 180)
        result = client.with { |conn| conn.set(key, value, ttl).positive? }
        cache_logger.debug "[cache] SET #{key} ttl=#{ttl} success=#{result} value_class=#{value.class}"
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: :memcached_set, key: key, ttl: ttl)
        raise
      end

      def delete(key)
        result = client.with { |conn| conn.delete(key) == true }
        cache_logger.debug "[cache] DELETE #{key} success=#{result}"
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: :memcached_delete, key: key)
        raise
      end

      def flush(delay = 0)
        result = client.with { |conn| conn.flush(delay).first }
        cache_logger.debug '[cache] FLUSH completed'
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: false, operation: :memcached_flush, delay: delay)
        raise
      end

      private

      def cache_logger
        @component_logger || log
      end

      def shared_dalli_logger
        if defined?(Legion::Cache) && Legion::Cache.respond_to?(:log)
          Legion::Cache.log
        else
          cache_logger
        end
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
