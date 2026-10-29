# legion-cache

Caching wrapper for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides a consistent interface for Memcached (via `dalli`) and Redis (via `redis` gem) with connection pooling. Driver selection is config-driven.

**Version**: 1.4.3

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

# Both drivers use keyword TTLs. Use synchronous writes for read-after-write.
Legion::Cache.set('foobar', 'testing', ttl: 10, async: false)
Legion::Cache.get('foobar')                         # => 'testing'
Legion::Cache.fetch('computed', ttl: 60) { 'value' } # computes only on a miss
Legion::Cache.set_nx('once', 'first', ttl: 60)       # atomic insert-if-absent
Legion::Cache.mset({ 'one' => 1, 'two' => 2 }, ttl: 60, async: false)
Legion::Cache.mget('one', 'two')
Legion::Cache.delete('foobar', async: false)

# Redis: deletes only this namespace. Memcached: flushes the entire server.
Legion::Cache.flush

Legion::Cache.shutdown
```

### Asynchronous Writes

`set`, `delete`, and `mset` default to `async: true`. A `true` return means the
mutation was admitted, not that the backend has committed it. A stopped or full
writer returns `false`; it never executes overflow work on the caller's thread.
For `mset`, a `false` result can mean partial admission.

Each tier has its own bounded writer. Accepted asynchronous mutations for the
same key execute in admission order; other keys can execute concurrently.
Capacity is `async.pool_size + async.queue_size` outstanding operations.
Synchronous writes bypass the queue and do not act as barriers for earlier
asynchronous work. Use one mode consistently when ordering matters.

Use `async: false`, `set_sync`, `delete_sync`, or `mset_sync` when the following
read must observe the write. Shutdown drains accepted work up to the configured
deadline, then terminates remaining workers before closing the backend.

## Lite Mode (No Infrastructure)

When `LEGION_MODE=lite` is set, `Legion::Cache` activates the pure in-memory `Memory` adapter, bypassing Redis and Memcached entirely:

```ruby
ENV['LEGION_MODE'] = 'lite'
Legion::Cache.setup
Legion::Cache.using_memory?   # => true
Legion::Cache.set('key', 'value', ttl: 60, async: false)
Legion::Cache.get('key')      # => 'value'
```

Memory and the method-cache fallback use bounded, mutex-protected storage:
10,000 entries by default, with oldest-entry eviction. Expired entries are
reclaimed in the background even when never read again. Cleanup workers stop
when no expiring entries remain; clearing or closing storage wakes and joins
them. `Legion::Cache::Memory.setup(max_entries: 1000)` changes Memory's capacity.

## Two-Tier Cache

Legion::Cache supports a shared remote cache and an independent Local cache.
Setup performs a backend health check. If shared setup or a later operation
fails with a connection error, the operation is retried against healthy Local
when `failback_to_local` is enabled. Background reconnection returns traffic to
shared only after a successful health check. Setting `reconnect.enabled` to
`false` disables that worker. Setting `cache.enabled` to `false` disables the
shared facade entirely: no lazy connection and no automatic Local fallback.

```ruby
# Shared cache connects to remote cluster; Local connects to localhost
Legion::Cache.setup          # starts Local first, then tries shared
Legion::Cache.using_local?   # => true if shared was unreachable
Legion::Cache.local          # => Legion::Cache::Local

# Use Local directly if needed
Legion::Cache::Local.setup
Legion::Cache::Local.set('key', 'value', ttl: 60, async: false)
Legion::Cache::Local.get('key')  # => 'value'
Legion::Cache::Local.shutdown
```

Local uses its own configuration, namespace (`legion_local`), connection pool
(size 5, timeout 3 seconds), and default TTL (21,600 seconds). Redis scalar,
batch, hash, and sorted-set keys all include the selected tier's namespace.

Local `set`, `delete`, and `mset` accept `async:` (default `true`). After setup,
asynchronous mutations use a dedicated Local writer; pass `async: false` when a
following read must see the mutation immediately. `set_sync`, `delete_sync`, and
`mset_sync` are always synchronous. Shared-cache fallback does not enqueue the
same mutation a second time.

Local shutdown, close, restart, and reset drain pending mutations before
releasing the driver, up to the configured shutdown timeout. Restart rebuilds
the driver even after close or reset. Local uses the same overload rejection
and per-key ordering rules as the shared writer.

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
  "pool_checkout_timeout": 5,
  "default_ttl": 3600,
  "expires_in": 0,
  "failback_to_local": true,
  "async": {
    "pool_size": 4,
    "queue_size": 1000,
    "shutdown_timeout": 5
  },
  "reconnect": {
    "enabled": true,
    "initial_delay": 1,
    "max_delay": 60
  }
}
```

These are the `Legion::Settings[:cache]` settings. Driver selection prefers
`dalli` when installed and otherwise uses `redis`; an explicit `driver` wins.
Shared pool size defaults to 10 for both drivers. TTLs are seconds; ordinary
`ttl: 0` disables expiration. Batch writes apply the same TTL as single writes.

### Driver Names

Supported driver names: `memcached` (or `dalli`), `redis`. All names are normalized internally — `"memcached"` and `"dalli"` are equivalent.

### Server Resolution

Both `server` (a string) and `servers` (an array) are accepted. Missing ports
default to 11211 for Memcached and 6379 for Redis; duplicates are removed.
Memcached uses the resolved server list. Standalone Redis uses its first
endpoint; use `cluster` for Redis Cluster. Redis URLs preserve credentials and
database selection.

An explicit `server:` or `servers:` passed to setup/restart replaces inherited
endpoints and clears an inherited cluster unless `cluster:` is also explicit.
Local settings do not inherit shared credentials, database, cluster, or TLS.

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
- Dalli 3.x and 4.x are supported. Dalli 5 is excluded because it removes the binary protocol and SASL authentication; configure `username` and `password` for SASL-capable servers.
- `fetch` releases its pooled connection before running application code. Application exceptions propagate unchanged.
- Hash helpers use bounded CAS retries instead of read/modify/write overwrites, preserving concurrent field updates.
- Memcached `flush` is server-wide, not namespace-scoped. Do not use it on a server whose other namespaces must be preserved.

### Redis Cluster and TLS

Redis and `redis-clustering` support the 5.4.x and 6.x client families.
Cluster configuration uses the dedicated `Redis::Cluster` client:

```ruby
Legion::Settings[:cache].merge!(
  driver: 'redis',
  cluster: ['redis://cache-1.example:6380', 'redis://cache-2.example:6380'],
  namespace: 'legion',
  tls: { enabled: true, verify: 'peer', ca: '/etc/ssl/cache-ca.pem' }
)
Legion::Cache.setup
```

Configured TLS requires `Legion::Crypt::TLS` to be loaded. CA verification,
client certificates/keys, and optional `fixed_hostname` settings are forwarded
to cluster-discovered connections as well as startup nodes. Redis Cluster
supports database 0 only.

Redis `flush` scans and deletes only the configured namespace, including across
cluster nodes. Partial scan/deletion failures return failure rather than
reporting success or falling back to a global flush.

**Upgrade note:** Redis keys now consistently include the namespace. Previously
unprefixed entries are not migrated or read; expect a cold cache after upgrade.

### PHI Retention

Pass `phi: true` to facade or Memory writes to enforce
`cache.compliance.phi_max_ttl` (default 3600 seconds). Zero or negative PHI TTL
requests use the cap; larger TTLs are clamped. Facades apply their tier's
default when TTL is omitted, bounded by the same cap. The cap itself must be
finite and positive. This applies to synchronous/asynchronous writes, batches,
`set_nx`, and `cas`, including Local writes.

### Local Cache Settings

```json
{
  "driver": "dalli",
  "servers": ["127.0.0.1:11211"],
  "namespace": "legion_local",
  "pool_size": 5,
  "timeout": 3,
  "async": {
    "pool_size": 4,
    "queue_size": 1000,
    "shutdown_timeout": 5
  }
}
```

Override via `Legion::Settings[:cache_local]`.

## Method Caching

Runner modules can use `cache_method` to transparently cache method results with TTL:

```ruby
module Runners::Presence
  extend Legion::Cache::Cacheable

  cache_method :get_presence, ttl: 300

  def get_presence(token:, user_id: 'me', **)
    conn = graph_connection(token: token, **)
    response = conn.get("#{user_path(user_id)}/presence")
    { availability: response.body['availability'], activity: response.body['activity'] }
  end
end
```

Results are cached for five minutes per caller identity and arguments. Use `bypass_local_method_cache: true` to force-refresh:

```ruby
runner.get_presence(token: token, user_id: 'me')                                  # cached
runner.get_presence(token: token, user_id: 'me', bypass_local_method_cache: true) # fresh
```

Options: `ttl:` (seconds), `scope:` (`:local` or `:global`), and
`exclude_from_key:` (arguments to ignore). Authentication `token` values always
contribute to the SHA-256 key digest, even if listed for exclusion; plaintext
tokens never appear in cache keys. Anonymous modules have distinct identities.

Both scopes fall back to bounded in-process storage when the selected backend
is unavailable or rejects a write. Cache failures do not replace a successfully
computed method result with an exception; application exceptions still
propagate. Ordinary zero TTL means no expiration, subject to capacity eviction.

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
- Memcached or Redis server, unless using lite mode
- Dalli >= 3.0 and < 5.0; Redis and redis-clustering >= 5.4.1 and < 7.0

## License

Apache-2.0
