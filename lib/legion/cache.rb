# frozen_string_literal: true

require 'legion/cache/version'
require 'legion/cache/settings'

require 'legion/cache/memcached'
require 'legion/cache/redis'

module Legion
  module Cache
    if Legion::Settings[:cache][:driver] == 'redis'
      extend Legion::Cache::Redis
    else
      extend Legion::Cache::Memcached
    end

    class << self
      def setup(**)
        return Legion::Settings[:cache][:connected] = true if connected?

        return unless client(**Legion::Settings[:cache], **)

        @connected = true
        Legion::Settings[:cache][:connected] = true
      end

      def shutdown
        Legion::Logging.info 'Shutting down Legion::Cache'
        close
        Legion::Settings[:cache][:connected] = false
      end
    end
  end
end
