# legion-cache

Caching wrapper for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides a consistent interface for Memcached (via `dalli`) and Redis (via `redis` gem) with connection pooling. Driver selection is config-driven.

**Version**: 1.3.17

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

# Redis driver — TTL is the third positional argument
Legion::Cache.set('foobar', 'testing', 10)
Legion::Cache.get('foobar')    # => 'testing'
Legion::Cache.delete('foobar') # => true
Legion::Cache.flush            # flushdb

Legion::Cache.shutdown
```

## Lite Mode (No Infrastructure)

When `LEGION_MODE=lite` is set, `Legion::Cache` activates the pure in-memory `Memory` adapter, bypassing Redis and Memcached entirely:

```ruby
ENV['LEGION_MODE'] = 'lite'
Legion::Cache.setup
Legion::Cache.using_memory?   # => true
Legion::Cache.set('key', 'value', 60)
Legion::Cache.get('key')      # => 'value'
```

The Memory adapter is thread-safe (Mutex), supports TTL expiry, and exposes the same `get`/`set`/`fetch`/`delete`/`flush` interface. Shutdown cleanly tears it down.

## Two-Tier Cache

Legion::Cache supports a two-tier architecture: a shared remote cluster and a local per-machine cache. If the shared cluster is unreachable at setup, all operations transparently fall back to local.

```ruby
# Shared cache connects to remote cluster; Local connects to localhost
Legion::Cache.setup          # starts Local first, then tries shared
Legion::Cache.using_local?   # => true if shared was unreachable
Legion::Cache.local          # => Legion::Cache::Local

# Use Local directly if needed
Legion::Cache::Local.setup
Legion::Cache::Local.set('key', 'value', 60)
Legion::Cache::Local.get('key')  # => 'value'
Legion::Cache::Local.shutdown
```

Local uses a separate namespace (`legion_local`) and independent connection pool (pool_size: 5, timeout: 3) so it never collides with the shared tier.

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

### Driver Names

Supported driver names: `memcached` (or `dalli`), `redis`. All names are normalized internally — `"memcached"` and `"dalli"` are equivalent.

### Server Resolution

Both `server` (singular string) and `servers` (array) are accepted and merged. Default ports are injected per driver when omitted: 11211 for memcached, 6379 for redis. Duplicates are removed.

```json
{
  "cache": {
    "driver": "memcached",
    "server": "10.0.0.5",
    "servers": ["10.0.0.6", "10.0.0.7:22122"]
  }
}
```

### Memcached notes

- `value_max_bytes` defaults to **8MB**. Dalli enforces a 1MB client-side limit by default, which silently rejects large values. This default overrides that. Your Memcached server should also be started with `-I 8m` to match.
- Redis default pool size is 20; Memcached default pool size is 10.

### Local Cache Settings

```json
{
  "driver": "dalli",
  "servers": ["127.0.0.1:11211"],
  "namespace": "legion_local",
  "pool_size": 5,
  "timeout": 3
}
```

Override via `Legion::Settings[:cache_local]`.

## Method Caching

Runner modules can use `cache_method` to transparently cache method results with TTL:

```ruby
module Runners::Presence
  extend Legion::Cache::Cacheable

  cache_method :get_presence, ttl: 300, exclude_from_key: [:token]

  def get_presence(user_id: 'me', **)
    conn = graph_connection(**)
    response = conn.get("#{user_path(user_id)}/presence")
    { availability: response.body['availability'], activity: response.body['activity'] }
  end
end
```

Every caller of `get_presence` gets cached results for 5 minutes. Use `bypass_local_method_cache: true` to force-refresh:

```ruby
runner.get_presence(user_id: 'me')                                    # cached
runner.get_presence(user_id: 'me', bypass_local_method_cache: true)   # fresh
```

Options: `ttl:` (seconds), `scope:` (`:local` or `:global`), `exclude_from_key:` (args to ignore in cache key). Falls back to in-memory store when no cache backend is available.

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
