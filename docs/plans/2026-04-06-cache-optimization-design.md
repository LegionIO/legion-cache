# Legion::Cache Optimization Design

**Date**: 2026-04-06
**Author**: Matthew Iverson (@Esity)
**Status**: Approved

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
- String values -> stored with `type:string` prefix byte
- Hash/Array/JSON-serializable -> `Legion::JSON.dump` with `type:json` prefix byte

**On `get`:**
- `type:json` prefix -> `Legion::JSON.load`
- `type:string` or no prefix (legacy data) -> return raw string
- Deserialization failure -> return raw string, log warning

Memcached uses Dalli's `serializer` option (already `Legion::JSON`). Memory stores Ruby objects directly. No changes needed for either.

`RedisHash` module is unchanged -- it remains the explicit "I want Redis data structures" path.

### 5. `enabled?` vs `connected?`

- `enabled?` = desired state from `Legion::Settings[:cache][:enabled]` (or `:cache_local`). Config-driven. Connection errors never change it.
- `connected?` = actual state. Cached boolean flag, no network pings.
- If `enabled? == false`: `connected?` is always `false`, no retries, no connections. Reads return `nil`, async writes no-op (`true`), sync writes raise.
- If `enabled? == true && connected? == false`: reconnector runs in background.

### 6. AsyncWriter

New file: `lib/legion/cache/async_writer.rb`

Uses `Concurrent::ThreadPoolExecutor` (already a transitive dependency).

```ruby
Legion::Cache::AsyncWriter
  .start(pool_size:, queue_size:, shutdown_timeout:)
  .stop(timeout:)          # drains queue, waits up to timeout, then kills
  .enqueue(&block)         # submits work to the pool
  .running?
  .pool_size               # current thread count
  .queue_depth             # pending jobs
  .processed_count         # total completed (atomic counter)
```

Settings (`Legion::Settings[:cache][:async]`):
```json
{
  "pool_size": 4,
  "queue_size": 1000,
  "shutdown_timeout": 5
}
```

**Backpressure:** When queue is full, `enqueue` falls back to synchronous execution and logs a warning.

**Shutdown:** `Legion::Cache.shutdown` calls `AsyncWriter.stop(timeout:)`:
1. Stop accepting new work
2. Wait up to `shutdown_timeout` seconds for drain
3. Force-kill remaining threads if timeout exceeded
4. Log drained vs abandoned job counts

### 7. Reconnector

New file: `lib/legion/cache/reconnector.rb`

One instance per tier (shared, local).

**Behavior:**
- Triggered when lifecycle fails and `enabled? == true`
- Only one reconnect loop per tier (mutex-guarded)
- Exponential backoff: 1s -> 2s -> 4s -> ... -> 60s cap
- Unlimited retries while `enabled? == true`
- On success: reset backoff, set `@connected = true`
- On `enabled?` becoming `false`: stop immediately
- Read/write callers never trigger reconnect directly (no thundering herd)

Settings (`Legion::Settings[:cache][:reconnect]`):
```json
{
  "initial_delay": 1,
  "max_delay": 60,
  "enabled": true
}
```

### 8. Stats

```ruby
Legion::Cache.stats
# => {
#   driver: "dalli",
#   servers: ["10.0.1.50:11211", "10.0.1.51:11211"],
#   enabled: true,
#   connected: true,
#   using_local: false,
#   using_memory: false,
#   pool_size: 10,
#   pool_available: 7,
#   async_pool_size: 4,
#   async_queue_depth: 12,
#   async_processed: 4832,
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

### 10. Logger Consistency

- All modules use `Legion::Logging::Helper` and call `log` directly.
- Remove `cache_logger` / `shared_dalli_logger` indirection.
- Dalli's internal logger set to `log`.
- Uniform log format: `[cache:<tier>] <OP> key=<key> ...` where tier is `shared`, `local`, or `memory`.

## Implementation Phases

Each phase is a standalone commit.

### Phase 1: Unify method signatures
- TTL keyword-only across all drivers and both tiers
- Set default TTLs (global: 3600, local: 21600)
- Drop `flush(delay)` -> `flush`
- Normalize `client` kwargs across Memcached/Redis
- Fix Memcached `get` nil-check bug
- Use `log` everywhere, remove logger indirection

### Phase 2: Exception handling
- Wrap every public method per the exception model table
- All use `handle_exception` with `operation:` context
- Reads: handled, return nil
- Sync writes: not handled, re-raise
- Lifecycle: handled, set `@connected = false`

### Phase 3: Transparent JSON serialization (Redis)
- Add prefix-byte serialization in Redis `set_sync`/`get`
- Graceful fallback for legacy keys (no prefix = raw string)
- No changes to Memcached or Memory

### Phase 4: `enabled?`, `connected?`, `stats`
- Add `enabled?` to both tiers backed by settings
- Guard all operations on `enabled?`
- Add `stats` method with servers, pool info, async pool size, uptime

### Phase 5: AsyncWriter
- New `async_writer.rb` with `Concurrent::ThreadPoolExecutor`
- Add `set_sync`/`set_async`/`set` delegation pattern for `set`, `delete`, `mset`
- `async: true` default on writes
- Backpressure: synchronous fallback when queue full

### Phase 6: Reconnector
- New `reconnector.rb` with exponential backoff (1s -> 60s cap)
- Wire into lifecycle failures
- Respects `enabled?` -- stops if disabled
- One instance per tier, mutex-guarded

### Phase 7: Wire together + specs
- Integration between AsyncWriter, Reconnector, and both tiers
- Shutdown drains async pool with configurable timeout
- Update all specs to cover new behavior
