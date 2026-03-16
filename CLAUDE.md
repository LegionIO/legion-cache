# legion-cache: Caching Layer for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Caching wrapper for the LegionIO framework. Provides a consistent interface for Memcached (via `dalli`) and Redis (via `redis` gem) with connection pooling. Driver selection is config-driven.

**GitHub**: https://github.com/LegionIO/legion-cache
**License**: Apache-2.0

## Architecture

```
Legion::Cache (singleton module)
├── .setup(**opts)          # Connect to cache backend
├── .get(key)               # Retrieve cached value
├── .fetch(key, ttl)        # Get with block/TTL support (Memcached only; alias for get on Redis)
├── .set(key, value, ttl)   # Store value with optional TTL (positional on Memcached, keyword on Redis)
├── .delete(key)            # Remove a key
├── .flush                  # Flush all keys (flush(delay) on Memcached, flushdb on Redis)
├── .connected?             # Connection status
├── .size                   # Total pool connections
├── .available              # Idle pool connections
├── .restart(**opts)        # Close and reconnect pool with optional new opts
├── .shutdown               # Close connections, mark disconnected
├── .local                  # Accessor for Legion::Cache::Local
├── .using_local?           # Whether fallback to local is active
│
├── Memcached               # Dalli-based Memcached driver (default)
│   └── Uses connection_pool for thread safety
│   └── value_max_bytes defaults to 8MB (overrides dalli's 1MB client-side limit)
├── Redis                   # Redis driver
│   └── Uses connection_pool for thread safety
│   └── Default pool_size is 20 (Memcached default is 10)
├── Local                   # Local cache tier (localhost Redis/Memcached, fallback target)
│   ├── .setup              # Connect to local cache server (auto-detect driver)
│   ├── .shutdown           # Close local connection
│   ├── .connected?         # Whether local cache is active
│   ├── .get/set/delete/fetch/flush  # Cache operations on local tier
│   ├── .restart(**opts)    # Close and reconnect with new opts
│   └── .reset!             # Clear all state (testing)
├── Pool                    # Connection pool management (connected?, size, available, close, restart)
├── Settings                # Default cache config + driver auto-detection
└── Version
```

### Key Design Patterns

- **Driver Selection at Load Time**: `Legion::Settings[:cache][:driver]` determines which module gets `extend`ed into `Legion::Cache` (`'redis'` or `'dalli'`)
- **Connection Pooling**: Both drivers use `connection_pool` gem for thread-safe access
- **Unified Interface**: Same `get`/`set`/`delete`/`flush`/`connected?`/`shutdown` methods regardless of backend
- **TTL Signature Difference**: Memcached `set(key, value, ttl)` uses a positional TTL (default 180s); Redis `set(key, value, ttl: nil)` uses a keyword TTL

### Two-Tier Cache Architecture

- **Shared** (`Legion::Cache`) — remote Redis/Memcached cluster for cross-node caching
- **Local** (`Legion::Cache::Local`) — localhost Redis/Memcached for per-machine caching
- **Fallback**: If shared cluster is unreachable at setup, all operations transparently delegate to Local
- Both tiers use the same driver modules (`Memcached`/`Redis`) with independent connection pools
- Local uses `.dup` on the driver module to get isolated `@client`/`@connected` state

## Default Settings

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
  "expires_in": 0,
  "serializer": "Legion::JSON"
}
```

The `driver` is auto-detected at load time: prefers `dalli`, falls back to `redis` if dalli is unavailable. Both gems are required dependencies so auto-detection is a fallback for unusual environments.

### Local Default Settings

`Legion::Cache::Settings.local` provides independent defaults for the local tier:

```json
{
  "driver": "dalli",
  "servers": ["127.0.0.1:11211"],
  "connected": false,
  "enabled": true,
  "namespace": "legion_local",
  "compress": false,
  "failover": false,
  "threadsafe": true,
  "cache_nils": false,
  "pool_size": 5,
  "timeout": 3,
  "expires_in": 0,
  "serializer": "Legion::JSON"
}
```

### Memcached value_max_bytes

Dalli enforces a 1MB client-side limit by default (`value_max_bytes: 1_048_576`). The Memcached driver overrides this to **8MB** (`8 * 1024 * 1024`) unless explicitly set. This prevents silent rejection of large cached values. The Memcached server must also be started with `-I 8m` to accept values up to 8MB server-side.

## Dependencies

| Gem | Purpose |
|-----|---------|
| `dalli` (>= 3.0) | Memcached client |
| `redis` (>= 5.0) | Redis client |
| `connection_pool` (>= 2.4) | Thread-safe connection pooling |
| `legion-logging` | Logging |
| `legion-settings` | Configuration |

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/cache.rb` | Module entry, driver selection, setup/shutdown, fallback wiring |
| `lib/legion/cache/memcached.rb` | Dalli/Memcached driver implementation |
| `lib/legion/cache/redis.rb` | Redis driver implementation |
| `lib/legion/cache/local.rb` | Local cache tier (localhost, fallback target) |
| `lib/legion/cache/pool.rb` | Connection pool management |
| `lib/legion/cache/settings.rb` | Default configuration + local defaults |
| `lib/legion/cache/version.rb` | VERSION constant |

## Role in LegionIO

Optional caching layer initialized during `Legion::Service` startup. Used by `legion-data` for model caching (Sequel caching plugin) and by extensions for general-purpose caching.

---

**Maintained By**: Matthew Iverson (@Esity)
