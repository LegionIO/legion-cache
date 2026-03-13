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
├── .setup(**opts)     # Connect to cache backend
├── .get(key)          # Retrieve cached value
├── .set(key, value, ttl:)  # Store value with optional TTL
├── .connected?        # Connection status
├── .shutdown          # Close connections
│
├── Memcached          # Dalli-based Memcached driver (default)
│   └── Uses connection_pool for thread safety
├── Redis              # Redis driver
│   └── Uses connection_pool for thread safety
├── Pool               # Connection pool management
├── Settings           # Default cache config
└── Version
```

### Key Design Patterns

- **Driver Selection at Load Time**: `Legion::Settings[:cache][:driver]` determines which module gets `include`d into `Legion::Cache` (`'redis'` or `'dalli'`)
- **Connection Pooling**: Both drivers use `connection_pool` gem for thread-safe access
- **Unified Interface**: Same `get`/`set`/`connected?`/`shutdown` methods regardless of backend

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
  "expires_in": 0
}
```

The `driver` is auto-detected at load time: prefers `dalli`, falls back to `redis` if dalli is unavailable. Both gems are required dependencies so auto-detection is a fallback for unusual environments.

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
| `lib/legion/cache.rb` | Module entry, driver selection, setup/shutdown |
| `lib/legion/cache/memcached.rb` | Dalli/Memcached driver implementation |
| `lib/legion/cache/redis.rb` | Redis driver implementation |
| `lib/legion/cache/pool.rb` | Connection pool management |
| `lib/legion/cache/settings.rb` | Default configuration |
| `lib/legion/cache/version.rb` | VERSION constant |

## Role in LegionIO

Optional caching layer initialized during `Legion::Service` startup. Used by `legion-data` for model caching (Sequel caching plugin) and by extensions for general-purpose caching.

---

**Maintained By**: Matthew Iverson (@Esity)
