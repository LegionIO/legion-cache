# Legion::Cache Optimization Design

**Date**: 2026-04-06
**Author**: Matthew Iverson (@Esity)
**Status**: Approved (revised after adversarial review round 1)

## Goals

Normalize the Legion::Cache codebase so that all drivers (Memcached, Redis, Memory) and both tiers (shared, local) present a uniform interface. Add async writes, background reconnection, transparent serialization, and operational observability.

## Key Decisions

### 1. Unified Method Signatures

Every driver and both tiers share this exact public API:

```ruby
# Core operations
get(key)                                              # -> value or nil
set(key, value, ttl: nil, async: true, phi: false)    # -> true (async), true/false or raise (sync)
fetch(key, ttl: nil, &block)                          # -> value or nil
delete(key, async: true)                              # -> true (async), true/false or raise (sync)
flush                                                 # -> true/false
mget(*keys)                                           # -> Hash { key => value }
mset(hash, ttl: nil, async: true)                     # -> true (async), true/false or raise (sync)

# Lifecycle
setup(**)
shutdown
restart(**)

# Status
connected?                                            # actual connection state (cached flag, no network call)
enabled?                                              # desired state from Legion::Settings
stats                                                 # frozen Hash snapshot
```

- TTL is keyword-only (`ttl:`) everywhere, always Integer seconds, always optional.
- Default TTL: global = 3600 (1 hour), local = 21600 (6 hours).
- `flush` drops the `delay` argument (Memcached-specific, Redis doesn't support it).
- `async: true` is the default for all write operations.
- **Internal callers** (`Cacheable`, `Helper`) always use `async: false` to preserve read-after-write consistency. External callers get async by default.

### 2. Write Delegation Pattern

Every write method (`set`, `delete`, `mset`) delegates to sync/async variants:

```
set(key, value, ttl:, async: true)
  -> async: true  -> set_async(key, value, ttl:) -> pool worker -> set_sync(key, value, ttl:)
  -> async: false -> set_sync(key, value, ttl:)
```

`set_sync` is the single source of truth for the actual driver write. Every path converges there.

Same pattern for `delete` and `mset`:
```
delete(key, async:)     -> delete_sync(key) / delete_async(key)
mset(hash, ttl:, async:) -> mset_sync(hash, ttl:) / mset_async(hash, ttl:)
```

**Note on `mset` TTL:** Redis and Memcached `mset` do not natively support per-entry TTL. `mset_sync` is implemented as per-key `set_sync` calls with the TTL applied to each entry. This trades batch atomicity for uniform TTL behavior. This is acceptable because `mset` is a convenience method, not a performance-critical path.

### 3. Exception Handling Model

| Category | Re-raise? | `handled:` | Returns on failure |
|---|---|---|---|
| Reads (`get`, `fetch`, `mget`) | No | `true` | `nil` / `{}` |
| Sync writes (`set_sync`, `delete_sync`, `mset_sync`) | Yes | `false` | raises |
| Async writes (inside pool worker) | No | `true` | logged only |
| Lifecycle (`setup`, `shutdown`, `restart`) | No | `true` | sets `@connected = false` |

Every `handle_exception` call includes `operation:` context for traceability.

Fixes:
- Memcached `get` currently checks `result[0]` before `result.nil?` -- removed.
- Redis catches `::Redis::BaseError` -- changed to `StandardError` for consistency.

### 4. Transparent JSON Serialization (Redis driver)

When using the Redis driver, complex types are serialized transparently:

**On `set_sync`:**
- String values -> stored with `type:string` prefix byte (`"S\x00"`)
- Hash/Array/JSON-serializable -> `Legion::JSON.dump` with `type:json` prefix byte (`"J\x00"`)
- Both prefix constants are `.b` (binary encoding) frozen strings.

**On `get`:**
- Force binary encoding on raw value (`raw = raw.b`) before prefix checks to avoid `Encoding::CompatibilityError`
- `type:json` prefix -> `Legion::JSON.load`
- `type:string` or no prefix (legacy data) -> return raw string
- Deserialization failure -> return raw string, log warning

**On `mget`:** Apply `deserialize_value` to each returned value.

**On `mset_sync`:** Apply `serialize_value` to each value (implemented as per-key `set_sync`).

Memcached uses Dalli's `serializer` option (already `Legion::JSON`). Memory stores Ruby objects directly. No changes needed for either.

`RedisHash` module is unchanged -- it operates in its own keyspace using native Redis hash data structures. It does not share keys with `set`/`get` and is not affected by the prefix-byte serialization scheme.

### 5. `enabled?` vs `connected?`

- `enabled?` = desired state from `Legion::Settings[:cache][:enabled]` (or `:cache_local`). Config-driven. Connection errors never change it.
- `connected?` = actual state. Cached boolean flag, no network pings.
- If `enabled? == false`: `connected?` is always `false`, no retries, no connections. Reads return `nil`, async writes no-op (`true`), sync writes raise. **`setup` returns immediately without attempting any connections.**
- If `enabled? == true && connected? == false`: reconnector runs in background.

### 6. AsyncWriter

New file: `lib/legion/cache/async_writer.rb`

Uses `Concurrent::ThreadPoolExecutor`. Requires `concurrent-ruby` (added as direct gemspec dependency).

```ruby
Legion::Cache::AsyncWriter
  .start(pool_size:, queue_size:, shutdown_timeout:)
  .stop(timeout:)          # drains queue, waits up to timeout, then kills
  .enqueue(&block)         # submits work to the pool
  .running?
  .pool_size               # current thread count
  .queue_depth             # pending jobs
  .processed_count         # total successful completions (atomic counter)
  .failed_count            # total failed jobs (atomic counter)
```

Settings (`Legion::Settings[:cache][:async]`):
```json
{
  "pool_size": 4,
  "queue_size": 1000,
  "shutdown_timeout": 5
}
```

**Thread safety:** `enqueue` captures a local reference to `@executor` before checking `running?` to prevent TOCTOU races with concurrent `stop` calls. Uses `Concurrent::AtomicBoolean` and `Concurrent::AtomicFixnum` instead of raw Mutex for counters and flags.

**Backpressure:** When queue is full, `enqueue` falls back to synchronous execution and logs a warning.

**Shutdown:** `Legion::Cache.shutdown` drains the async writer FIRST (before closing pools), then calls `AsyncWriter.stop(timeout:)`:
1. Stop accepting new work
2. Wait up to `shutdown_timeout` seconds for drain
3. Force-kill remaining threads if timeout exceeded
4. Log drained vs abandoned job counts

**Tier awareness:** Each tier (shared, local) gets its own `AsyncWriter` instance. Local reads settings from `Legion::Settings[:cache_local][:async]`, shared reads from `Legion::Settings[:cache][:async]`.

### 7. Reconnector

New file: `lib/legion/cache/reconnector.rb`

One instance per tier (shared, local). Requires `require 'concurrent'`.

**Behavior:**
- Triggered when shared setup fails and `enabled? == true` — **regardless of whether local fallback succeeds**
- Only one reconnect loop per tier (guarded by `Concurrent::AtomicBoolean`)
- Exponential backoff: 1s -> 2s -> 4s -> ... -> 60s cap
- Unlimited retries while `enabled? == true`
- On success: log attempt count, then reset backoff counter
- On `enabled?` becoming `false`: stop immediately
- Read/write callers never trigger reconnect directly (no thundering herd)
- Uses `Concurrent::AtomicFixnum` for attempt counter (reset via `Concurrent::AtomicFixnum.new(0)`, not `.value=`)

**Reconnect path:** A separate `reconnect_shared!` method (and `reconnect_local!` for Local) that raises on failure is used by the reconnect loop. This is distinct from `setup_shared` which rescues internally for normal boot flow.

**Thread safety for `stop`:** Sets `@stop_signal` (AtomicBoolean) inside synchronization, then releases the lock before calling `@thread.join` to prevent deadlock.

Settings (`Legion::Settings[:cache][:reconnect]`):
```json
{
  "initial_delay": 1,
  "max_delay": 60,
  "enabled": true
}
```

**Tier awareness:** Local reconnector reads from `Legion::Settings[:cache_local][:reconnect]`.

### 8. Stats

```ruby
Legion::Cache.stats
# => {
#   driver: "memory",        # varies: "dalli", "redis", "memory"
#   servers: ["127.0.0.1:11211"],
#   enabled: true,
#   connected: true,
#   using_local: false,
#   using_memory: true,
#   pool_size: 1,
#   pool_available: 1,
#   async_pool_size: 4,
#   async_queue_depth: 0,
#   async_processed: 4832,
#   async_failed: 3,
#   reconnect_attempts: 0,
#   uptime: 3600
# }
```

`Legion::Cache::Local.stats` has the same shape minus `using_local`/`using_memory`.

### 9. Connection Args Consistency

Both drivers accept the same base kwargs:

```ruby
client(
  server: nil,
  servers: [],
  pool_size: nil,
  timeout: nil,
  username: nil,
  password: nil,
  logger: nil,
  **opts          # driver-specific extras (cluster:, replica:, db: for Redis)
)
```

Resolution chain: explicit kwarg -> `Legion::Settings[:cache]` -> `Legion::Cache::Settings.default`

**Redis Cluster flush:** Per-node connections in `cluster_flush` must pass the same credentials (`username`, `password`) and TLS options used by the main connection. These are extracted from the stored connection opts.

### 10. Logger Consistency

- All modules use `Legion::Logging::Helper` and call `log` directly.
- Remove `cache_logger` / `shared_dalli_logger` indirection.
- Dalli's internal logger set to `log`.
- Uniform log format: `[cache:<tier>] <OP> key=<key> ...` where tier is `shared`, `local`, or `memory`.

### 11. Concurrency Primitives

Prefer `concurrent-ruby` primitives over raw `Mutex`:
- `Concurrent::AtomicBoolean` for flags (`@connected`, `@stop_signal`)
- `Concurrent::AtomicFixnum` for counters (`@processed`, `@failed`, `@attempts`)
- `Concurrent::ThreadPoolExecutor` for async writer
- Only use `Mutex` when `concurrent-ruby` has no suitable alternative

## Implementation Phases

Each phase is a standalone commit, except where noted.

### Phase 1: Unify method signatures
- TTL keyword-only across all drivers and both tiers
- Set default TTLs (global: 3600, local: 21600)
- Drop `flush(delay)` -> `flush`
- Normalize `client` kwargs across Memcached/Redis
- Fix Memcached `get` nil-check bug
- Use `log` everywhere, remove logger indirection
- **Helper and Cacheable updates are included in this phase** (single atomic commit for top-level, helper, and cacheable signature changes to avoid broken intermediate state)

### Phase 2: Exception handling
- Wrap every public method per the exception model table
- All use `handle_exception` with `operation:` context
- Reads: handled, return nil
- Sync writes: not handled, re-raise
- Lifecycle: handled, set `@connected = false`

### Phase 3: Transparent JSON serialization (Redis)
- Add prefix-byte serialization in Redis `set_sync`/`get`
- Apply `deserialize_value` to `mget` results
- Apply `serialize_value` in `mset_sync` (per-key iteration)
- Force binary encoding before prefix checks
- Graceful fallback for legacy keys (no prefix = raw string)
- No changes to Memcached or Memory
- Fix Redis cluster flush to pass credentials and TLS options

### Phase 4: `enabled?`, `connected?`, `stats`
- Add `enabled?` to both tiers backed by settings
- Guard all operations on `enabled?` — **including `setup`**
- Add `stats` method with servers, pool info, async pool size, async failed count, uptime

### Phase 5: AsyncWriter
- New `async_writer.rb` with `Concurrent::ThreadPoolExecutor`
- Add `set_sync`/`set_async`/`set` delegation pattern for `set`, `delete`, `mset`
- `async: true` default on writes; Helper and Cacheable hardcode `async: false`
- Backpressure: synchronous fallback when queue full
- Separate `processed_count` and `failed_count` counters
- TOCTOU-safe enqueue via local executor reference capture
- Drain async writer before closing pools on shutdown
- Tier-aware settings (`:cache` vs `:cache_local`)

### Phase 6: Reconnector
- New `reconnector.rb` with exponential backoff (1s -> 60s cap)
- `require 'concurrent'` at top of file
- Separate `reconnect_shared!` / `reconnect_local!` raising methods for the retry loop
- Start shared reconnector even when local fallback succeeds
- Wire into lifecycle failures
- Respects `enabled?` -- stops if disabled
- One instance per tier, guarded by `Concurrent::AtomicBoolean`
- `stop` releases lock before `thread.join` (no deadlock)
- Reset attempt counter via new `AtomicFixnum` instance, log count before reset
- Tier-aware settings (`:cache` vs `:cache_local`)

### Phase 7: Wire together + specs
- Integration between AsyncWriter, Reconnector, and both tiers
- Shutdown drains async pool with configurable timeout
- Update all specs to cover new behavior

## Adversarial Review Round 1 — Resolution Log

### Fixed in this revision

| # | Source | Finding | Resolution |
|---|--------|---------|------------|
| 1 | All 3 | `mget`/`mset` excluded from serialization | Added to Phase 3: deserialize in mget, serialize via per-key set_sync in mset_sync |
| 2 | Sonnet, 5.3 | Missing `require 'concurrent'` in reconnector | Added to Phase 6 |
| 3 | Sonnet, 5.3 | Helper/Cacheable positional TTL breaks between commits | Merged into Phase 1 as single atomic commit |
| 4 | 5.4, 5.3 | Redis cluster flush ignores auth/TLS | Added to Phase 3 and §9 |
| 5 | Sonnet | `@attempts.value = 0` invalid on AtomicFixnum | Fixed in §7: use new AtomicFixnum instance, log before reset |
| 6 | Sonnet, 5.3 | AsyncWriter enqueue TOCTOU race | Fixed in §6: capture local executor reference |
| 7 | Sonnet | Reconnector stop deadlocks (mutex held across join) | Fixed in §7: release lock before join |
| 8 | 5.4, 5.3 | Reconnector can't detect failure (setup_shared rescues) | Added `reconnect_shared!` raising method in §7 |
| 9 | 5.3 | Reconnector only starts when both tiers fail | Fixed in §7: starts whenever shared fails |
| 10 | 5.4, 5.3 | `enabled?` must guard `setup` | Fixed in §5: setup returns immediately when disabled |
| 11 | 5.4 | Local tier reads `:cache` for async/reconnect settings | Fixed in §6 and §7: tier-aware settings parameter |
| 12 | Sonnet | Stats example shows wrong driver | Fixed in §8: example shows `"memory"` with note |
| 13 | Sonnet | Serialization prefix encoding compatibility | Fixed in §4: force binary encoding before checks |
| 14 | Sonnet | `processed_count` counts failures | Fixed in §6: separate `failed_count` counter |
| 15 | 5.3 | `mset(ttl:)` not natively implementable | Documented in §2: implemented as per-key set_sync |
| 16 | All 3 | Async writes and lifecycle share no lock | No lifecycle mutex needed — reconnector reconnects to same servers, routing flags only change at boot/shutdown |
| 17 | Sonnet | Pool reads wrong settings for Local | Documented: fallback is dead code after proper client() init |

### Dismissed

| # | Source | Finding | Reason |
|---|--------|---------|--------|
| 1 | Sonnet | Memory module shared state / dup | Existing behavior, Memory is singleton in lite mode, never dup'd |
| 2 | Sonnet | `enabled?` fail-open during boot | Correct — before settings load, cache should attempt to work |
| 3 | Sonnet | Reconnector specs use sleep | Acceptable for now, can improve later |
| 4 | Sonnet | Task ordering dependency (Task 5 before 2/3) | Tasks execute sequentially, not a real issue |

### User decisions

| # | Finding | Decision |
|---|---------|----------|
| 1 | `async: true` default breaks read-after-write | Keep `async: true` default. Helper and Cacheable hardcode `async: false`. |
| 2 | TTL 60→3600 breaking change | Keep 3600/21600. LEX extensions specify own TTL. PHI cap is non-concern for local tier. |
| 3 | Minor vs major version bump | Keep 1.4.0. Internal gem, all callers controlled. |
| 4 | Lifecycle mutex for reconnector races | Not needed. Reconnector reconnects to same servers, no cluster swaps. |
