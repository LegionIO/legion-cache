# frozen_string_literal: true

module Legion
  module Cache
    module Helper
      def cache_namespace
        @cache_namespace ||= derive_cache_namespace
      end

      def cache_set(key, value, ttl: 60)
        Legion::Cache.set(cache_namespace + key, value, ttl)
      end

      def cache_get(key)
        Legion::Cache.get(cache_namespace + key)
      end

      def cache_delete(key)
        Legion::Cache.delete(cache_namespace + key)
      end

      def cache_fetch(key, ttl: 60, &)
        Legion::Cache.fetch(cache_namespace + key, ttl, &)
      end

      def local_cache_set(key, value, ttl: 60)
        Legion::Cache::Local.set(cache_namespace + key, value, ttl)
      end

      def local_cache_get(key)
        Legion::Cache::Local.get(cache_namespace + key)
      end

      def local_cache_delete(key)
        Legion::Cache::Local.delete(cache_namespace + key)
      end

      def local_cache_fetch(key, ttl: 60, &)
        Legion::Cache::Local.fetch(cache_namespace + key, ttl, &)
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
