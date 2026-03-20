# frozen_string_literal: true

require 'digest'

module Legion
  module Cache
    module Cacheable
      def self.build_cache_key(mod_name, method_name, exclude:, **kwargs)
        filtered = kwargs.reject { |k, _| exclude.include?(k) }
        args_hash = Digest::MD5.hexdigest(filtered.sort.to_s)
        "#{mod_name}.#{method_name}.#{args_hash}"
      end

      # In-memory fallback store (class-level, process-wide)
      def self.memory_store
        @memory_store ||= {}
      end

      def self.memory_read(key)
        entry = memory_store[key]
        return nil unless entry
        return nil if Time.now.utc > entry[:expires_at]

        entry[:value]
      end

      def self.memory_write(key, value, ttl)
        memory_store[key] = { value: value, expires_at: Time.now.utc + ttl }
      end

      def self.memory_clear!
        @memory_store = {}
      end
    end
  end
end
