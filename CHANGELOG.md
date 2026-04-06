# Changelog

## [Unreleased]

## [1.4.1] - 2026-04-06

### Fixed
- AsyncWriter TOCTOU race condition in enqueue (capture local executor reference)
- Reconnector deadlock on stop (release mutex before thread.join)
- Reconnector NoMethodError on successful reconnect (AtomicFixnum reset)
- Missing `require 'concurrent'` in reconnector.rb
- Redis cluster flush now passes auth/TLS credentials to per-node connections
- Async writer drains before pool close on shutdown
- Serialization applied to mget/mset_sync (was only on set_sync/get)
- Binary encoding forced before serialization prefix checks

### Added
- Automatic failback to Local tier when shared cache is disabled or disconnected (configurable via `failback_to_local: true`)
- `mget`/`mset` methods on Memory adapter for interface consistency
- Public `pool` accessor on `Legion::Cache` (replaces direct `@client` access)
- `failed_count` counter in AsyncWriter stats (`async_failed` in stats hash)
- `reconnect_shared!` raising method for reconnector connect_block
- End-to-end lifecycle integration test (shared fail -> local failback -> reconnect)

### Changed
- Helper and Cacheable use `async: false` for read-after-write consistency
- AsyncWriter and Reconnector are tier-aware (`settings_key:` parameter, `:cache_local` for local tier)
- Redis driver `pool_size` resolved from settings (was hardcoded to 20)
- Pool checkout timeout separated from operation timeout (new `pool_checkout_timeout` setting)
- Reconnector starts on any shared failure (even when local fallback succeeds)
- `setup` guarded by `enabled?` check
- State flags (`@connected`, `@using_local`, `@using_memory`) refactored to `Concurrent::AtomicBoolean`
- Reconnector `@stop_signal` refactored to `Concurrent::AtomicBoolean`
- `RedisHash` uses public `pool` accessor instead of `instance_variable_get(:@client)`

## [1.4.0] - 2026-04-06

### Added
- Async write support via `Legion::Cache::AsyncWriter` backed by `concurrent-ruby` ThreadPoolExecutor
- `set`, `delete`, and `mset` now accept `async:` keyword (default `true`) for non-blocking writes
- `Legion::Cache::Reconnector` with exponential backoff (1s to 60s) for background reconnection
- Reconnector auto-starts when both shared and local cache are unavailable at setup
- `enabled?` guard on both shared and local tiers
- `stats` method returning frozen Hash with driver, connection, pool, async, and reconnect metrics
- `set_sync`, `delete_sync`, `mset_sync` explicit synchronous write methods on all tiers
- Async and reconnect default settings in `Legion::Cache::Settings`
- Transparent JSON serialization for Redis driver (prefix-byte protocol, backward-compatible with legacy data)

### Changed
- All cache drivers now use keyword TTL (`ttl:`) instead of positional arguments
- `flush` takes no arguments across all drivers (was `flush(delay = 0)`)
- `Helper` module updated: `FALLBACK_TTL` changed from 60 to 3600, all delegations use keyword signatures, `cache_set`/`cache_delete`/`cache_mset` accept `async:` keyword
- `Cacheable` module updated: `cache_write` and `local_cache_write` use keyword TTL
- Default TTL changed from 60 to 3600 (shared) and 21600 (local)
- Version bump from 1.3.22 to 1.4.0

### Fixed
- Unified exception handling model: reads return nil (handled), sync writes re-raise, lifecycle handles internally

## [1.3.22] - 2026-04-03

### Fixed
- Default `servers` no longer pre-computed at require time with stale driver port; resolves Redis connecting to `127.0.0.1:11211` (memcached default) instead of user-configured host

## [1.3.21] - 2026-04-02

### Fixed
- Preserve `fetch` block behavior across shared, local, memory, and Redis cache paths; local-cache failures now fall back to the in-process cache and cached `false` values are retained correctly
- Move shared adapter selection to runtime setup/client calls, register cache defaults through `Legion::Cache::Settings`, and normalize IPv4/hostname/IPv6 server addresses consistently
- Restrict Redis hash/sorted-set helpers to the actual Redis backend and enforce documented TTL behavior for helper batch writes
- Make the default `bundle exec rspec` suite hermetic by excluding service-backed integration specs unless `RUN_INTEGRATION_SPECS=1`

### Changed
- Uplift cache logging internals to `Legion::Logging::Helper`, replacing direct logger calls with helper-provided `log` usage across cache runtime modules
- Route rescued cache adapter/helper/setup failures through `handle_exception` and expand runtime `info`/`debug`/`error` coverage for shared, local, memory, pool, and RedisHash flows
- Require `legion-logging >= 1.5.0` at runtime so helper exception handling is always available

## [1.3.20] - 2026-03-31

### Fixed
- Forward `timeout` setting to `::Redis.new` — was silently using redis gem's 1.0s default instead of configured 5s, causing spurious timeouts on service mesh connections
- Forward `timeout` to `::Redis.new` in cluster mode path as well

### Changed
- Increase `reconnect_attempts` from `1` to `[0, 0.5, 1]` (shared) / `[0, 0.25, 0.5]` (local) — 3 retries with escalating backoff instead of 1 instant retry, improving resilience for service mesh and remote Redis connections

## [1.3.19] - 2026-03-31

### Added
- `cache_mget` / `cache_mset` (and `local_cache_mget` / `local_cache_mset`) on `Helper` mixin — delegates to Redis batch ops, falls back to sequential get/set on Memcached (closes #3)
- `cache_hset`, `cache_hgetall`, `cache_hdel`, `cache_zadd`, `cache_zrangebyscore`, `cache_zrem`, `cache_expire` on `Helper` mixin — delegates to `RedisHash` with namespace prefixing; hash ops fall back to JSON-serialized Memcached values, sorted-set ops raise `NotImplementedError`, expire is a no-op on Memcached (closes #4)

## [1.3.18] - 2026-03-29

### Added
- Layered TTL resolution in Helper (per-call → LEX override → Settings → FALLBACK_TTL)
- `cache_default_ttl` / `local_cache_default_ttl` — LEX-overridable default TTL methods
- `cache_exist?` / `local_cache_exist?` — key existence checks
- `cache_connected?` / `local_cache_connected?` — connection status helpers
- `cache_pool_size` / `cache_pool_available` — pool info (shared tier)
- `local_cache_pool_size` / `local_cache_pool_available` — pool info (local tier)
- `phi:` keyword argument on `cache_set` / `local_cache_set` for PHI TTL enforcement
- `default_ttl` key in Settings.default and Settings.local (defaults to 60)

## [1.3.17] - 2026-03-25

### Added
- `Legion::Cache::RedisHash` module: Redis hash and sorted-set operations (`hset`, `hgetall`, `hdel`, `zadd`, `zrangebyscore`, `zrem`, `expire`) with `redis_available?` guard and safe defaults when Redis is not connected
- Auto-required from `legion/cache.rb` alongside the existing Redis adapter

## [1.3.16] - 2026-03-25

### Fixed
- Accept ttl as positional or keyword argument in Cache.set for caller flexibility
- Align Redis.set signature to positional ttl arg matching parent module convention

## [1.3.15] - 2026-03-24

### Added
- PHI-aware TTL enforcement: `Cache.set` accepts `phi: true` keyword option; TTL is capped at `cache.compliance.phi_max_ttl` (default 3600s) when set
- `Legion::Cache.phi_max_ttl` — reads `cache.compliance.phi_max_ttl` from settings with 3600s default
- `Legion::Cache.enforce_phi_ttl(ttl, phi:)` — public helper for PHI TTL cap logic

## [1.3.14] - 2026-03-24

### Added
- `username`, `password`, `db`, and `reconnect_attempts` options to Redis `client` and `build_redis_client`
- Corresponding nil/default entries in `Settings.default` and `Settings.local`

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
