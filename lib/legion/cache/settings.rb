# frozen_string_literal: true

require 'ipaddr'
require 'legion/logging/helper'

module Legion
  module Cache
    module Settings
      extend Legion::Logging::Helper

      begin
        require 'legion/settings'
      rescue StandardError => e
        handle_exception(e,
                         level:     :error,
                         handled:   true,
                         operation: :cache_settings_require_legion_settings)
      end

      def self.default
        {
          driver:             driver,
          servers:            [],
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
          default_ttl:        3600,
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
          servers:            [],
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
          default_ttl:        21_600,
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

        all.map! { |s| normalize_server(s, port: port) }
        resolved = all.uniq
        log.debug "Legion::Cache::Settings resolved driver=#{gem_driver} servers=#{resolved.join(', ')}"
        resolved
      end

      def self.parse_server_address(server, default_port:)
        raw = server.to_s.strip
        return ['127.0.0.1', default_port] if raw.empty?

        bracketed = raw.match(/\A\[(?<host>[^\]]+)\](?::(?<port>\d+))?\z/)
        return [bracketed[:host], (bracketed[:port] || default_port).to_i] if bracketed

        return [raw, default_port] if ipv6_literal?(raw)

        host, explicit_port = raw.split(':', 2)
        if explicit_port&.match?(/\A\d+\z/)
          [host, explicit_port.to_i]
        else
          [raw, default_port]
        end
      end

      def self.register_defaults!
        return unless defined?(Legion::Settings) && Legion::Settings.respond_to?(:merge_settings)

        Legion::Settings.merge_settings(:cache, default)
        Legion::Settings.merge_settings(:cache_local, local)
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
          log.debug "Legion::Cache::Settings selected driver=#{prefer}"
          prefer
        elsif Gem::Specification.find_all_by_name(secondary).any?
          log.info "Legion::Cache::Settings falling back driver=#{secondary} preferred=#{prefer}"
          secondary
        else
          error = NameError.new('Legion::Cache.driver is nil')
          handle_exception(error, level: :error, handled: false, operation: :cache_settings_driver, preferred: prefer)
          raise error
        end
      end

      def self.normalize_server(server, port:)
        host, resolved_port = parse_server_address(server, default_port: port)
        format_server(host, resolved_port)
      end

      def self.format_server(host, port)
        return "[#{host}]:#{port}" if ipv6_literal?(host)

        "#{host}:#{port}"
      end

      def self.ipv6_literal?(value)
        IPAddr.new(value).ipv6?
      rescue IPAddr::InvalidAddressError
        false
      end

      register_defaults!
    end
  end
end
