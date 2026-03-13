# frozen_string_literal: true

require 'connection_pool'

module Legion
  module Cache
    module Pool
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
      end

      def restart(**opts)
        close
        @client = nil
        client_hash = opts
        client_hash[:pool_size] = opts[:pool_size] if opts.key? :pool_size
        client_hash[:timeout] = opts[:timeout] if opts.key? :timeout
        client(**client_hash)
        @connected = true
      end
    end
  end
end
