# frozen_string_literal: true

begin
  require 'legion/settings'
rescue StandardError
  # empty block
end

module Legion
  module Cache
    module Settings
      Legion::Settings.merge_settings(:cache, default) if Legion::Settings.method_defined? :merge_settings
      def self.default
        {
          driver:     driver,
          servers:    ['127.0.0.1:11211'],
          connected:  false,
          enabled:    true,
          namespace:  'legion',
          compress:   false,
          failover:   true,
          threadsafe: true,
          expires_in: 0,
          cache_nils: false,
          pool_size:  10,
          timeout:    5,
          serializer: Legion::JSON
        }
      end

      def self.driver(prefer = 'dalli')
        secondary = prefer == 'dalli' ? 'redis' : 'dalli'
        if Gem::Specification.find_all_by_name(prefer).any?
          prefer
        elsif Gem::Specification.find_all_by_name(secondary).any?
          secondary
        else
          raise NameError('Legion::Cache.driver is nil')
        end
      end
    end
  end
end
