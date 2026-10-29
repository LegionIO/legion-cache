# frozen_string_literal: true

require 'connection_pool'
require 'concurrent'
require 'timeout'
require 'socket'
require 'legion/logging/helper'

module Legion
  module Cache
    module Pool
      extend self
      extend Legion::Logging::Helper

      def connected?
        @connected&.value == true
      end

      def size
        client.size
      end

      def timeout
        @timeout ||= Legion::Settings[:cache][:timeout] || 5
      end

      def pool_size
        @pool_size ||= Legion::Settings[:cache][:pool_size] || 10
      end

      def available
        client.available
      end

      def close
        pool = @client
        @client = nil
        cache_mark_connected(false)
        pool&.shutdown(&:close)
        log.info "#{pool_log_name} pool closed"
      end

      def restart(**)
        close
        client(**)
        log.info "#{pool_log_name} pool restarted"
      end

      private

      def cache_mark_connected(value)
        @connected ||= Concurrent::AtomicBoolean.new(false)
        @connected.value = value
      end

      def cache_backend_failed(error)
        return unless cache_connection_error?(error)

        cache_mark_connected(false)
        @cache_failure_callback&.call(error)
      end

      def cache_connection_error?(error)
        return true if error.is_a?(IOError) || error.is_a?(SystemCallError) || error.is_a?(Timeout::Error) || error.is_a?(SocketError)
        return true if error.is_a?(ConnectionPool::TimeoutError)
        return error.errors.values.any? { |nested| cache_connection_error?(nested) } if error.instance_of?(::Redis::Cluster::CommandErrorCollection)

        error.class.ancestors.any? do |type|
          %w[Dalli::NetworkError Dalli::RingError Redis::BaseConnectionError RedisClient::ConnectionError
             Redis::Cluster::InitialSetupError Redis::Cluster::NodeMightBeDown].include?(type.name)
        end
      end

      def pool_log_name
        if respond_to?(:name)
          label = name.to_s
          return label unless label.empty? || label.start_with?('#<')
        end

        segments = if instance_variable_defined?(:@component_logger) && @component_logger.respond_to?(:segments)
                     Array(@component_logger.segments)
                   elsif log.respond_to?(:segments)
                     Array(log.segments)
                   else
                     []
                   end

        segments.empty? ? 'cache.pool' : segments.join('.')
      end
    end
  end
end
