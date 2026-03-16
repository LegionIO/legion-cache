# legion-cache

Caching wrapper for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides a consistent interface for Memcached (via `dalli`) and Redis (via `redis` gem) with connection pooling. Driver selection is config-driven.

**Version**: 1.2.1

## Installation

```bash
gem install legion-cache
```

Or add to your Gemfile:

```ruby
gem 'legion-cache'
```

## Usage

```ruby
require 'legion/cache'

Legion::Cache.setup
Legion::Cache.connected? # => true

# Memcached driver (default) — TTL is a positional argument, default 180s
Legion::Cache.set('foobar', 'testing', 10)
Legion::Cache.get('foobar')    # => 'testing'
Legion::Cache.fetch('foobar')  # => 'testing' (get with block support)
Legion::Cache.delete('foobar') # => true
Legion::Cache.flush            # flush all keys

# Redis driver — TTL is a keyword argument
Legion::Cache.set('foobar', 'testing', ttl: 10)
Legion::Cache.get('foobar')    # => 'testing'
Legion::Cache.delete('foobar') # => true
Legion::Cache.flush            # flushdb

Legion::Cache.shutdown
```

## Configuration

```json
{
  "driver": "dalli",
  "servers": ["127.0.0.1:11211"],
  "connected": false,
  "enabled": true,
  "namespace": "legion",
  "compress": false,
  "failover": true,
  "threadsafe": true,
  "cache_nils": false,
  "pool_size": 10,
  "timeout": 5,
  "expires_in": 0
}
```

The driver is auto-detected at load time: prefers `dalli` (Memcached) if available, falls back to `redis`. Override with `"driver": "redis"` and update `servers` to point at your Redis instance.

### Memcached notes

- `value_max_bytes` defaults to **8MB**. Dalli enforces a 1MB client-side limit by default, which silently rejects large values. This default overrides that. Your Memcached server should also be started with `-I 8m` to match.
- Redis default pool size is 20; Memcached default pool size is 10.

## Pool API

```ruby
Legion::Cache.connected?  # => true/false
Legion::Cache.size        # total pool connections
Legion::Cache.available   # idle pool connections
Legion::Cache.restart     # close and reconnect pool
Legion::Cache.shutdown    # close pool and mark disconnected
```

## Requirements

- Ruby >= 3.4
- Memcached or Redis server

## License

Apache-2.0
