# Changelog

## [1.3.13] - 2026-03-24

### Changed
- Reindex docs: update CLAUDE.md and README with Memory adapter and Helper mixin docs

## [1.3.12] - 2026-03-24

### Added
- `Legion::Cache::Memory` adapter module for lite mode: pure in-memory cache with TTL expiry and thread-safe Mutex synchronization
- Cache `setup` auto-detects `LEGION_MODE=lite` and activates Memory adapter, skipping Redis/Memcached
- `@using_memory` flag routes `get`/`set`/`fetch`/`delete`/`flush` through Memory adapter
- `shutdown` cleanly tears down Memory adapter when active

## [1.3.11] - 2026-03-22

### Added
- `Legion::Cache::Helper` module: injectable cache mixin for LEX extensions
- Namespaced `cache_set`, `cache_get`, `cache_delete`, `cache_fetch` for shared cache
- Namespaced `local_cache_set`, `local_cache_get`, `local_cache_delete`, `local_cache_fetch` for per-node local cache

## [1.3.10] - 2026-03-22

### Changed
- Updated gemspec dependency version constraints: legion-logging >= 1.2.8, legion-settings >= 1.3.12

## [1.3.9] - 2026-03-22

### Changed
- Added `Legion::Logging` calls (guarded with `defined?`) to all previously silent rescue blocks
- `memcached.rb`: debug log on `memcached_tls_settings` failure
- `redis.rb`: warn log on `cluster_flush` fallback; debug log on `resolved_redis_address` and `cache_tls_settings` failures
- `settings.rb`: stdlib `warn` on `legion/settings` require failure (Logging not yet available at that point)

## [1.3.8] - 2026-03-22

### Changed
- Memcached driver now logs server addresses on connect
- Local cache now logs server addresses on connect
- Shared cache setup log now shows full server list instead of just first server

## [1.3.7] - 2026-03-22

### Added
- Redis driver: `.debug` logging on get (hit/miss), set (ttl/success), delete, flush, mget (key count), mset (key count)
- Redis driver: `.info` on successful client creation with host/port address
- Redis driver: private `resolved_redis_address` helper for extracting address at connect time
- Pool: `.info` on close and restart
- Cacheable: `.debug` on cache hit/miss in wrapper; `.warn` on swallowed errors in `local_cache_read`/`local_cache_write`
- Local: `.debug` on get/set/fetch/delete/flush operations
- Cache: `.info` on successful shared cache setup (driver + server)
- All new logging calls guarded with `if defined?(Legion::Logging)` for standalone use

## [1.3.6] - 2026-03-21

### Added
- Redis Cluster mode: `cluster:`, `replica:`, `fixed_hostname:` options in `build_redis_client`
- `cluster_mode?` predicate for runtime cluster detection
- `mget(*keys)` and `mset(hash)` with automatic slot-aware grouping for cross-slot operations
- Cluster-aware `flush` that iterates all primary nodes via `CLUSTER NODES`
- Failover logging: `Redis::BaseError` rescues log via `Legion::Logging.warn` before re-raising
- Settings defaults: `cluster: nil`, `replica: false`, `fixed_hostname: nil`

### Fixed
- `get`, `set`, `delete`, `flush` visibility changed from private to public (were inaccessible on the module directly)

## [1.3.5] - 2026-03-21

### Added
- TLS support for Redis driver: `ssl: true` + `ssl_params` when TLS enabled via `Legion::Crypt::TLS.resolve`
- TLS support for Memcached driver: `ssl_context` option when TLS enabled via `Legion::Crypt::TLS.resolve`
- Port-based auto-detection: Redis TLS port 6380, Memcached TLS port 11207

## [1.3.3] - 2026-03-20

### Fixed
- Serializer option (`Legion::JSON`) now correctly flows through to `Dalli::Client.new`, preventing Dalli from falling back to Marshal and emitting a security warning

## [1.3.2] - 2026-03-20

### Added
- `Legion::Cache::Cacheable` module for transparent method-level caching
- `cache_method` DSL: declare cached methods with TTL, scope, and key exclusions
- `build_cache_key`: deterministic MD5-based cache keys from module path + method + filtered args
- `bypass_local_method_cache:` kwarg for force-refresh on cached methods
- In-memory fallback store with TTL expiry when no cache backend is available
- `memory_clear!` class method for test isolation

## [1.3.1] - 2026-03-20

### Added
- `Settings.normalize_driver` — maps `:memcached`, `:dalli`, `:redis` to internal gem names
- `Settings.resolve_servers` — merges `server:` (string) and `servers:` (array), injects default port per driver (memcached: 11211, redis: 6379), deduplicates
- `Settings::DEFAULT_PORTS` constant for driver default ports

### Fixed
- Redis driver now uses configured `server:`/`servers:` instead of hardcoded localhost
- Memcached driver accepts `server:` (singular) in addition to `servers:` (plural)

### Changed
- `Settings.default` and `Settings.local` use `resolve_servers` for driver-aware server defaults
- Driver selection in `cache.rb` and `local.rb` uses `normalize_driver` for consistent name handling

## [1.3.0] - 2026-03-16

### Added
- `Legion::Cache::Local` module for local Redis/Memcached caching
- `Settings.local` with independent defaults (namespace: `legion_local`, pool_size: 5, timeout: 3)
- Transparent fallback: shared cache failure at setup redirects all operations to Local
- `Legion::Cache.local` accessor, `Legion::Cache.using_local?` query

## [1.2.1] - 2026-03-16

### Fixed
- Set dalli `value_max_bytes` to 8MB by default — dalli enforces a 1MB client-side limit that prevented large cache values from being stored even when memcached server allows larger items

## [1.2.0]

Moving from BitBucket to GitHub. All git history is reset from this point on
