# frozen_string_literal: true

module Legion
  module Cache
    module Helper
      FALLBACK_TTL = 60

      # --- TTL Resolution ---
      # Override in your LEX to set a custom default TTL for the extension.
      # Resolution chain: per-call ttl: kwarg -> LEX override -> Settings -> FALLBACK_TTL
      def cache_default_ttl
        return FALLBACK_TTL unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :default_ttl) || FALLBACK_TTL
      rescue StandardError
        FALLBACK_TTL
      end

      def local_cache_default_ttl
        return cache_default_ttl unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache_local, :default_ttl) || cache_default_ttl
      rescue StandardError
        cache_default_ttl
      end

      # --- Namespace ---

      def cache_namespace
        @cache_namespace ||= derive_cache_namespace
      end

      # --- Core Operations (shared tier) ---

      def cache_set(key, value, ttl: nil, phi: false)
        effective_ttl = ttl || cache_default_ttl
        Legion::Cache.set(cache_namespace + key, value, effective_ttl, phi: phi)
      end

      def cache_get(key)
        Legion::Cache.get(cache_namespace + key)
      end

      def cache_delete(key)
        Legion::Cache.delete(cache_namespace + key)
      end

      def cache_fetch(key, ttl: nil, &)
        effective_ttl = ttl || cache_default_ttl
        Legion::Cache.fetch(cache_namespace + key, effective_ttl, &)
      end

      def cache_exist?(key)
        !Legion::Cache.get(cache_namespace + key).nil?
      end

      # --- Core Operations (local tier) ---

      def local_cache_set(key, value, ttl: nil, phi: false)
        effective_ttl = ttl || local_cache_default_ttl
        effective_ttl = Legion::Cache.enforce_phi_ttl(effective_ttl, phi: phi)
        Legion::Cache::Local.set(cache_namespace + key, value, effective_ttl)
      end

      def local_cache_get(key)
        Legion::Cache::Local.get(cache_namespace + key)
      end

      def local_cache_delete(key)
        Legion::Cache::Local.delete(cache_namespace + key)
      end

      def local_cache_fetch(key, ttl: nil, &)
        effective_ttl = ttl || local_cache_default_ttl
        Legion::Cache::Local.fetch(cache_namespace + key, effective_ttl, &)
      end

      def local_cache_exist?(key)
        !Legion::Cache::Local.get(cache_namespace + key).nil?
      end

      # --- Status ---

      def cache_connected?
        Legion::Cache.connected?
      end

      def local_cache_connected?
        Legion::Cache::Local.connected?
      end

      # --- Pool Info ---

      def cache_pool_size
        return 0 unless cache_connected?

        Legion::Cache.pool_size
      rescue StandardError
        0
      end

      def cache_pool_available
        return 0 unless cache_connected?

        Legion::Cache.available
      rescue StandardError
        0
      end

      def local_cache_pool_size
        return 0 unless local_cache_connected?

        Legion::Cache::Local.pool_size
      rescue StandardError
        0
      end

      def local_cache_pool_available
        return 0 unless local_cache_connected?

        Legion::Cache::Local.available
      rescue StandardError
        0
      end

      private

      def derive_cache_namespace
        if respond_to?(:lex_filename)
          fname = lex_filename
          fname.is_a?(Array) ? fname.first : fname
        else
          derive_cache_namespace_from_class
        end
      end

      def derive_cache_namespace_from_class
        name = respond_to?(:ancestors) ? ancestors.first.to_s : self.class.to_s
        parts = name.split('::')
        ext_idx = parts.index('Extensions')
        target = if ext_idx && parts[ext_idx + 1]
                   parts[ext_idx + 1]
                 else
                   parts.last
                 end
        target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
      end
    end
  end
end
