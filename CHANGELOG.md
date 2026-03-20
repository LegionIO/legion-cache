# Changelog

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
