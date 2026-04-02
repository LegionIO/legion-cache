# frozen_string_literal: true

require 'connection_pool'
require 'legion/logging/helper'

module Legion
  module Cache
    module Pool
      extend self
      extend Legion::Logging::Helper

      def connected?
        @connected ||= false
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
        client.shutdown(&:close)
        @client = nil
        @connected = false
        log.info "#{pool_log_name} pool closed"
      end

      def restart(**opts)
        close
        @client = nil
        client_hash = opts
        client_hash[:pool_size] = opts[:pool_size] if opts.key? :pool_size
        client_hash[:timeout] = opts[:timeout] if opts.key? :timeout
        client(**client_hash)
        @connected = true
        log.info "#{pool_log_name} pool restarted"
      end

      private

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
