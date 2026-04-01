# frozen_string_literal: true

begin
  require 'legion/settings'
rescue StandardError => e
  warn "legion-cache: failed to require legion/settings: #{e.message}"
end

module Legion
  module Cache
    module Settings
      Legion::Settings.merge_settings(:cache, default) if Legion::Settings.method_defined? :merge_settings
      Legion::Settings.merge_settings(:cache_local, local) if Legion::Settings.method_defined? :merge_settings
      def self.default
        {
          driver:             driver,
          servers:            resolve_servers(driver: driver),
          connected:          false,
          enabled:            true,
          namespace:          'legion',
          compress:           false,
          failover:           true,
          threadsafe:         true,
          expires_in:         0,
          cache_nils:         false,
          pool_size:          10,
          timeout:            5,
          default_ttl:        60,
          serializer:         Legion::JSON,
          cluster:            nil,
          replica:            false,
          fixed_hostname:     nil,
          username:           nil,
          password:           nil,
          db:                 nil,
          reconnect_attempts: [0, 0.5, 1].freeze
        }
      end

      def self.local
        {
          driver:             driver,
          servers:            resolve_servers(driver: driver),
          connected:          false,
          enabled:            true,
          namespace:          'legion_local',
          compress:           false,
          failover:           true,
          threadsafe:         true,
          expires_in:         0,
          cache_nils:         false,
          pool_size:          5,
          timeout:            3,
          default_ttl:        60,
          serializer:         Legion::JSON,
          username:           nil,
          password:           nil,
          db:                 nil,
          reconnect_attempts: [0, 0.25, 0.5].freeze
        }
      end

      DEFAULT_PORTS = { 'dalli' => 11_211, 'redis' => 6379 }.freeze

      def self.resolve_servers(driver:, server: nil, servers: [], port: nil)
        gem_driver = normalize_driver(driver)
        port ||= DEFAULT_PORTS.fetch(gem_driver, 11_211)

        all = Array(servers) + Array(server)
        all = ["127.0.0.1:#{port}"] if all.empty?

        all.map! { |s| s.include?(':') ? s : "#{s}:#{port}" }
        all.uniq
      end

      def self.normalize_driver(name)
        case name.to_s
        when 'redis' then 'redis'
        when 'memcached', 'dalli' then 'dalli'
        else name.to_s
        end
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
