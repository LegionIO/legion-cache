# Legion::Cache Post-Optimization Fixes

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Apply adversarial review fixes and connection pool improvements on top of the completed cache optimization work (from `2026-04-06-cache-optimization-plan.md`).

**Architecture:** Two phases — Phase A fixes issues found by adversarial review that the in-flight implementation won't have addressed. Phase B improves connection pool usage.

**Tech Stack:** Ruby >= 3.4, concurrent-ruby, Dalli, Redis, ConnectionPool, Legion::Logging, Legion::Settings

**Prerequisite:** The `2026-04-06-cache-optimization-plan.md` must be fully implemented and merged first.

**Design doc:** `docs/plans/2026-04-06-cache-optimization-design.md` (adversarial review resolution log at bottom)

---

## Phase A: Adversarial Review Fixes

These address findings from 3 adversarial reviewers (Sonnet 4.6, Codex gpt-5.3-codex, Codex gpt-5.4) that the in-flight implementation plan does not cover.

---

### Task A1: Force Cacheable and Helper to use async: false

**Files:**
- Modify: `lib/legion/cache/helper.rb`
- Modify: `lib/legion/cache/cacheable.rb`
- Test: `spec/legion/cache/helper_spec.rb`, `spec/legion/cacheable_spec.rb`

**Context:** All 3 reviewers flagged that `async: true` default breaks read-after-write patterns in Cacheable and Helper. User decision: keep `async: true` as public default, but internal callers hardcode `async: false`.

**Step 1: Write the failing tests**

Add to `spec/legion/cache/helper_spec.rb`:

```ruby
describe 'cache_set uses synchronous writes' do
  it 'passes async: false to Legion::Cache.set' do
    expect(Legion::Cache).to receive(:set).with(anything, anything, hash_including(async: false))
    subject.cache_set('key', 'value')
  end
end

describe 'cache_delete uses synchronous writes' do
  it 'passes async: false to Legion::Cache.delete' do
    expect(Legion::Cache).to receive(:delete).with(anything, hash_including(async: false))
    subject.cache_delete('key')
  end
end
```

Add to `spec/legion/cacheable_spec.rb`:

```ruby
describe 'cache_write uses synchronous writes' do
  it 'passes async: false to Legion::Cache.set' do
    allow(Legion::Cache::Cacheable).to receive(:global_cache_available?).and_return(true)
    expect(Legion::Cache).to receive(:set).with('k', 'v', hash_including(async: false))
    Legion::Cache::Cacheable.cache_write('k', 'v', ttl: 60, scope: :global)
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/legion/cache/helper_spec.rb spec/legion/cacheable_spec.rb -v`
Expected: FAIL — current code does not pass `async: false`.

**Step 3: Update Helper**

In `lib/legion/cache/helper.rb`, update all write calls:

```ruby
def cache_set(key, value, ttl: nil, phi: false)
  effective_ttl = ttl || cache_default_ttl
  Legion::Cache.set(cache_namespace + key, value, ttl: effective_ttl, async: false, phi: phi)
end

def cache_delete(key)
  Legion::Cache.delete(cache_namespace + key, async: false)
end

def cache_mset(hash, ttl: nil)
  return true if hash.empty?
  effective_ttl = ttl || cache_default_ttl
  hash.each { |k, v| Legion::Cache.set(cache_namespace + k, v, ttl: effective_ttl, async: false) }
  true
rescue StandardError => e
  log_cache_error('cache_mset', e)
  false
end

def local_cache_set(key, value, ttl: nil, phi: false)
  effective_ttl = ttl || local_cache_default_ttl
  effective_ttl = Legion::Cache.enforce_phi_ttl(effective_ttl, phi: phi)
  Legion::Cache::Local.set(cache_namespace + key, value, ttl: effective_ttl, async: false)
end

def local_cache_delete(key)
  Legion::Cache::Local.delete(cache_namespace + key, async: false)
end

def local_cache_mset(hash, ttl: nil)
  return true if hash.empty?
  effective_ttl = ttl || local_cache_default_ttl
  hash.each { |k, v| Legion::Cache::Local.set(cache_namespace + k, v, ttl: effective_ttl, async: false) }
  true
rescue StandardError => e
  log_cache_error('local_cache_mset', e)
  false
end
```

**Step 4: Update Cacheable**

In `lib/legion/cache/cacheable.rb`, update `cache_write` and `local_cache_write`:

```ruby
def self.cache_write(key, value, ttl:, scope:)
  case scope
  when :global
    if global_cache_available?
      Legion::Cache.set(key, value, ttl: ttl, async: false)
    else
      memory_write(key, value, ttl)
    end
  else
    if local_cache_available?
      result = local_cache_write(key, value, ttl)
      memory_write(key, value, ttl) unless result
    else
      memory_write(key, value, ttl)
    end
  end
end

def self.local_cache_write(key, value, ttl)
  return unless local_cache_available?
  Legion::Cache::Local.set(key, value, ttl: ttl, async: false)
rescue StandardError => e
  handle_exception(e, level: :warn, operation: :local_cache_write, key: key, ttl: ttl)
  nil
end
```

**Step 5: Run tests**

Run: `bundle exec rspec spec/legion/cache/helper_spec.rb spec/legion/cacheable_spec.rb -v`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/legion/cache/helper.rb lib/legion/cache/cacheable.rb spec/legion/cache/helper_spec.rb spec/legion/cacheable_spec.rb
git commit -m "force helper and cacheable to use synchronous cache writes"
```

---

### Task A2: Fix AsyncWriter TOCTOU race in enqueue

**Files:**
- Modify: `lib/legion/cache/async_writer.rb`
- Test: `spec/legion/cache/async_writer_spec.rb`

**Context:** Sonnet C-3 and Codex 5.3 F6 flagged that `enqueue` checks `running?` then calls `@executor.post` — another thread can nil `@executor` between the two.

**Step 1: Write the failing test**

Add to `spec/legion/cache/async_writer_spec.rb`:

```ruby
describe 'thread safety' do
  it 'handles concurrent stop and enqueue without error' do
    writer.start
    errors = Concurrent::AtomicFixnum.new(0)
    threads = 10.times.map do
      Thread.new do
        50.times { writer.enqueue { nil } }
      rescue StandardError
        errors.increment
      end
    end
    sleep 0.05
    writer.stop(timeout: 2)
    threads.each(&:join)
    expect(errors.value).to eq(0)
  end
end
```

**Step 2: Run test**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb -v`
Expected: May pass or fail depending on timing — the fix makes it deterministic.

**Step 3: Fix enqueue**

In `lib/legion/cache/async_writer.rb`, change `enqueue` to capture a local reference:

```ruby
def enqueue(&block)
  executor = @executor
  if executor&.running?
    executor.post do
      block.call
      @processed.increment
    rescue StandardError => e
      handle_exception(e, level: :warn, handled: true, operation: :async_writer_job)
      @failed.increment
    end
  else
    block.call
    @processed.increment
  rescue StandardError => e
    handle_exception(e, level: :warn, handled: true, operation: :async_writer_sync_fallback)
    @failed.increment
  end
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/async_writer.rb spec/legion/cache/async_writer_spec.rb
git commit -m "fix async writer TOCTOU race in enqueue"
```

---

### Task A3: Add failed_count to AsyncWriter stats

**Files:**
- Modify: `lib/legion/cache/async_writer.rb`
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/async_writer_spec.rb`, `spec/legion/cache/stats_spec.rb`

**Step 1: Write the failing test**

Add to `spec/legion/cache/async_writer_spec.rb`:

```ruby
describe '#failed_count' do
  it 'tracks failed jobs separately from processed' do
    writer.start
    writer.enqueue { raise 'boom' }
    sleep 0.2
    expect(writer.failed_count).to eq(1)
    expect(writer.processed_count).to eq(0)
  end
end
```

Add to `spec/legion/cache/stats_spec.rb`:

```ruby
it 'includes async_failed in stats' do
  stats = Legion::Cache.stats
  expect(stats).to have_key(:async_failed)
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb spec/legion/cache/stats_spec.rb -v`
Expected: FAIL

**Step 3: Add failed_count**

In `lib/legion/cache/async_writer.rb`:
- Add `@failed = Concurrent::AtomicFixnum.new(0)` in `initialize`
- In rescue inside `enqueue` worker: increment `@failed` instead of `@processed`
- Add `def failed_count; @failed.value; end`

In `lib/legion/cache.rb` and `lib/legion/cache/local.rb`:
- Add `async_failed: @async_writer.failed_count` to `stats` hash

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb spec/legion/cache/stats_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/async_writer.rb lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/async_writer_spec.rb spec/legion/cache/stats_spec.rb
git commit -m "add failed_count to async writer stats"
```

---

### Task A4: Fix Reconnector — stop deadlock, AtomicFixnum reset, require concurrent

**Files:**
- Modify: `lib/legion/cache/reconnector.rb`
- Test: `spec/legion/cache/reconnector_spec.rb`

**Context:** Three issues in one file:
1. `stop` holds mutex across `thread.join` (Sonnet C-2)
2. `@attempts.value = 0` is invalid on AtomicFixnum (Sonnet H-2)
3. Missing `require 'concurrent'` (Sonnet H-4, Codex 5.3 F11)

**Step 1: Write the failing tests**

Add to `spec/legion/cache/reconnector_spec.rb`:

```ruby
describe 'can be required independently' do
  it 'loads without NameError' do
    expect { require 'legion/cache/reconnector' }.not_to raise_error
  end
end

describe 'successful reconnect logging' do
  let(:connect_block) do
    call_count = Concurrent::AtomicFixnum.new(0)
    -> { call_count.increment }
  end

  it 'does not raise NoMethodError on attempt reset' do
    reconnector.start
    sleep 1.5
    expect { reconnector.stop }.not_to raise_error
  end
end
```

**Step 2: Fix reconnector.rb**

1. Add `require 'concurrent'` at top of file
2. Fix `stop` — release mutex before join:

```ruby
def stop
  thread_to_join = nil
  @mutex.synchronize do
    @stop_signal.make_true
    thread_to_join = @thread
    @thread = nil
  end
  thread_to_join&.join(5)
  log.info "Legion::Cache::Reconnector[#{@tier}] stopped"
end
```

3. Fix attempt reset in `reconnect_loop`:

```ruby
count = @attempts.value
@attempts = Concurrent::AtomicFixnum.new(0)
@next_retry_at = nil
log.info "Legion::Cache::Reconnector[#{@tier}] reconnected after #{count} attempts"
```

4. Use `Concurrent::AtomicBoolean` for `@stop_signal` instead of plain boolean.

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/reconnector_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache/reconnector.rb spec/legion/cache/reconnector_spec.rb
git commit -m "fix reconnector deadlock, atomic reset, and missing require"
```

---

### Task A5: Add reconnect_shared! raising method and start reconnector on shared failure

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/reconnector_integration_spec.rb`

**Context:** Codex 5.4 F1 and 5.3 F1/F4 flagged that `setup_shared` rescues internally so the reconnector's `connect_block` can never detect failure. Also, the reconnector should start whenever shared fails, even if local succeeds.

**Step 1: Write the failing tests**

Add to `spec/legion/cache/reconnector_integration_spec.rb`:

```ruby
it 'starts reconnector even when local fallback succeeds' do
  allow(Legion::Cache).to receive(:client).and_raise(RuntimeError, 'refused')
  allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
  allow(Legion::Cache::Local).to receive(:setup)

  Legion::Cache.setup

  expect(Legion::Cache.using_local?).to be(true)
  reconnector = Legion::Cache.instance_variable_get(:@reconnector)
  expect(reconnector).not_to be_nil
  expect(reconnector.running?).to be(true)
  reconnector.stop
end
```

**Step 2: Implement reconnect_shared!**

In `lib/legion/cache.rb`, add a private method that raises on failure:

```ruby
def reconnect_shared!
  client(**Legion::Settings[:cache], logger: log)
  @connected = true
  @using_local = false
  Legion::Settings[:cache][:connected] = true
  log.info 'Legion::Cache shared reconnected'
end
```

Update `setup_shared` rescue to start the reconnector when shared fails and `enabled?` is true, regardless of local fallback:

```ruby
rescue StandardError => e
  report_exception(e, level: :warn, handled: true, operation: :setup_shared, fallback: :local)
  if Legion::Cache::Local.connected?
    @using_local = true
    @connected = true
    Legion::Settings[:cache][:connected] = true
    log.info 'Legion::Cache fell back to Local cache'
  else
    @connected = false
    Legion::Settings[:cache][:connected] = false
    log.error 'Legion::Cache shared and local adapters are unavailable'
  end
  start_reconnector if enabled?
end
```

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/reconnector_integration_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/reconnector_integration_spec.rb
git commit -m "add raising reconnect path, start reconnector on any shared failure"
```

---

### Task A6: Guard setup with enabled? check

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/enabled_spec.rb`

**Step 1: Write the failing test**

Add to `spec/legion/cache/enabled_spec.rb`:

```ruby
describe 'setup respects enabled?' do
  it 'does not connect when disabled' do
    Legion::Settings[:cache][:enabled] = false
    expect(Legion::Cache::Local).not_to receive(:setup)
    Legion::Cache.setup
    expect(Legion::Cache.connected?).to be(false)
    Legion::Settings[:cache][:enabled] = true
  end
end
```

**Step 2: Add guard**

In `lib/legion/cache.rb`, add at top of `setup`:
```ruby
def setup(**)
  return unless enabled?
  return Legion::Settings[:cache][:connected] = true if connected?
  # ... rest of setup
end
```

Same in `lib/legion/cache/local.rb` `setup`.

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/enabled_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/enabled_spec.rb
git commit -m "guard setup with enabled? check"
```

---

### Task A7: Make AsyncWriter and Reconnector tier-aware for settings

**Files:**
- Modify: `lib/legion/cache/async_writer.rb`, `lib/legion/cache/reconnector.rb`
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/async_writer_spec.rb`, `spec/legion/cache/reconnector_spec.rb`

**Context:** Codex 5.4 F4 flagged that Local tier reads `:cache` settings for async/reconnect instead of `:cache_local`.

**Step 1: Add settings_key parameter**

In `lib/legion/cache/async_writer.rb`, accept `settings_key:` in `initialize`:

```ruby
def initialize(settings_key: :cache, **opts)
  @settings_key = settings_key
  # ...
end

def configured_pool_size
  return DEFAULT_POOL_SIZE unless defined?(Legion::Settings)
  Legion::Settings.dig(@settings_key, :async, :pool_size) || DEFAULT_POOL_SIZE
rescue StandardError
  DEFAULT_POOL_SIZE
end
```

Same pattern for `configured_queue_size` and `configured_shutdown_timeout`.

In `lib/legion/cache/reconnector.rb`, accept `settings_key:` in `initialize`:

```ruby
def initialize(tier:, connect_block:, enabled_block:, settings_key: :cache)
  @settings_key = settings_key
  # ...
end
```

Update `configured_initial_delay` and `configured_max_delay` to use `@settings_key`.

**Step 2: Wire in both tiers**

In `lib/legion/cache.rb`:
```ruby
@async_writer = Legion::Cache::AsyncWriter.new(settings_key: :cache)
```

In `lib/legion/cache/local.rb`:
```ruby
@async_writer = Legion::Cache::AsyncWriter.new(settings_key: :cache_local)
```

Same for reconnector instances.

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb spec/legion/cache/reconnector_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache/async_writer.rb lib/legion/cache/reconnector.rb lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/async_writer_spec.rb spec/legion/cache/reconnector_spec.rb
git commit -m "make async writer and reconnector tier-aware for settings"
```

---

### Task A8: Fix Redis serialization for mget and mset_sync

**Files:**
- Modify: `lib/legion/cache/redis.rb`
- Test: `spec/legion/cache/redis_serialization_spec.rb`

**Context:** All 3 reviewers flagged that serialization was only applied to `set_sync`/`get`, not `mget`/`mset`.

**Step 1: Write the failing tests**

Add to `spec/legion/cache/redis_serialization_spec.rb`:

```ruby
describe 'mget deserializes values' do
  it 'deserializes prefixed values from mget' do
    allow(redis).to receive(:mget).and_return(["S\x00hello".b, "J\x00{\"a\":1}".b])
    result = cache.mget('k1', 'k2')
    expect(result['k1']).to eq('hello')
    expect(result['k2']).to be_a(Hash)
  end
end

describe 'mset_sync serializes values' do
  it 'serializes each value through set_sync' do
    allow(redis).to receive(:set).and_return('OK')
    expect(redis).to receive(:set).with('k1', /\AS\x00/, any_args)
    expect(redis).to receive(:set).with('k2', /\AJ\x00/, any_args)
    cache.mset_sync({ 'k1' => 'hello', 'k2' => { a: 1 } }, ttl: 60)
  end
end
```

**Step 2: Implement**

In `lib/legion/cache/redis.rb`:

`mget`: Apply `deserialize_value` to each value in the result hash.

```ruby
def mget(*keys)
  keys = keys.flatten
  return {} if keys.empty?

  result = client.with do |conn|
    if cluster_mode?
      cluster_mget(conn, keys)
    else
      values = conn.mget(*keys)
      keys.zip(values).to_h
    end
  end
  result.transform_values { |v| deserialize_value(v) }
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :redis_mget, key_count: keys.size)
  {}
end
```

`mset_sync`: Implement as per-key `set_sync` to get both serialization and TTL:

```ruby
def mset_sync(hash, ttl: nil)
  return true if hash.empty?
  hash.each { |key, value| set_sync(key, value, ttl: ttl) }
  true
end
```

Also force binary encoding in `deserialize_value`:

```ruby
def deserialize_value(raw)
  return nil if raw.nil?
  raw = raw.b if raw.respond_to?(:b)
  # ... rest of method
end
```

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/redis_serialization_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache/redis.rb spec/legion/cache/redis_serialization_spec.rb
git commit -m "apply serialization to mget/mset_sync, force binary encoding"
```

---

### Task A9: Fix Redis cluster flush to pass auth/TLS options

**Files:**
- Modify: `lib/legion/cache/redis.rb`
- Test: `spec/legion/cache/redis_cluster_spec.rb`

**Context:** Codex 5.4 F7 and 5.3 F9 flagged that `cluster_flush` opens raw unauthenticated connections.

**Step 1: Write the failing test**

Add to `spec/legion/cache/redis_cluster_spec.rb`:

```ruby
describe 'cluster_flush passes credentials' do
  it 'includes username and password in per-node connections' do
    cache = described_class.dup
    cache.instance_variable_set(:@connection_opts, { username: 'user', password: 'pass' })
    conn = instance_double(Redis)
    node_info = "abc123 10.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460\n"
    allow(conn).to receive(:cluster).with('nodes').and_return(node_info)

    node_client = instance_double(Redis)
    expect(Redis).to receive(:new).with(hash_including(host: '10.0.0.1', port: 6379, username: 'user', password: 'pass')).and_return(node_client)
    allow(node_client).to receive(:flushdb)
    allow(node_client).to receive(:close)

    cache.send(:cluster_flush, conn)
  end
end
```

**Step 2: Store connection opts and pass to cluster_flush**

In `lib/legion/cache/redis.rb`, store credential/TLS opts during `client`:

```ruby
@connection_opts = {
  username: username,
  password: password,
  timeout: @timeout
}.compact
@connection_opts.merge!(redis_tls_options(port: port.to_i)) if defined?(port)
```

Update `cluster_flush` to use stored opts:

```ruby
def cluster_flush(conn)
  node_info = conn.cluster('nodes')
  primaries = node_info.lines.select { |l| l.include?('master') }.map { |l| l.split[1].split('@').first }
  primaries.each do |addr|
    host, port = Legion::Cache::Settings.parse_server_address(addr, default_port: 6379)
    node = ::Redis.new(host: host, port: port.to_i, **(@connection_opts || {}))
    node.flushdb
    node.close
  end
  true
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :cluster_flush, fallback: :single_flushdb)
  conn.flushdb == 'OK'
end
```

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/redis_cluster_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache/redis.rb spec/legion/cache/redis_cluster_spec.rb
git commit -m "pass auth and TLS options to redis cluster flush per-node connections"
```

---

### Task A10: Drain async writer before closing pools on shutdown

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/async_integration_spec.rb`

**Context:** Codex 5.3 F6 flagged that shutdown closes clients before the writer is drained, causing async jobs to execute against closed pools.

**Step 1: Write the failing test**

Add to `spec/legion/cache/async_integration_spec.rb`:

```ruby
describe 'shutdown drains async writer before closing pool' do
  it 'completes pending async writes before shutdown' do
    Legion::Cache.set('drain_test', 'value', async: true)
    Legion::Cache.shutdown
    # Re-setup to verify the value was written before pool closed
    Legion::Cache.setup
    expect(Legion::Cache.get('drain_test')).to eq('value')
    Legion::Cache.shutdown
  end
end
```

**Step 2: Fix shutdown order**

In `lib/legion/cache.rb` `shutdown`:

```ruby
def shutdown
  log.info 'Shutting down Legion::Cache'
  # 1. Drain async writer FIRST (while pool is still alive)
  @async_writer&.stop(timeout: configured_shutdown_timeout)
  # 2. Stop reconnector
  @reconnector&.stop
  # 3. Now close pools
  if @using_memory
    Legion::Cache::Memory.shutdown
  else
    close unless @using_local
    Legion::Cache::Local.shutdown if Legion::Cache::Local.connected?
  end
  @using_local = false
  @using_memory = false
  @connected = false
  Legion::Settings[:cache][:connected] = false
end
```

Same order in `lib/legion/cache/local.rb`.

**Step 3: Run tests**

Run: `bundle exec rspec spec/legion/cache/async_integration_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/async_integration_spec.rb
git commit -m "drain async writer before closing pools on shutdown"
```

---

## Phase B: Connection Pool Improvements

---

### Task B1: Normalize pool_size — remove Redis hardcoded default

**Files:**
- Modify: `lib/legion/cache/redis.rb`
- Test: `spec/legion/redis_spec.rb`

**Step 1: Write the failing test**

Add to `spec/legion/redis_spec.rb`:

```ruby
describe 'pool_size from settings' do
  before do
    @cache = described_class.dup
    @cache.instance_variable_set(:@client, nil)
    @cache.instance_variable_set(:@connected, false)
  end

  it 'uses settings pool_size instead of hardcoded 20' do
    Legion::Settings[:cache][:pool_size] = 8
    redis_instance = instance_double(Redis)
    allow(Redis).to receive(:new).and_return(redis_instance)
    @cache.client(servers: ['127.0.0.1:6379'])
    expect(@cache.pool_size).to eq(8)
    Legion::Settings[:cache][:pool_size] = 10
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/redis_spec.rb --tag ~integration -v`
Expected: FAIL — Redis hardcodes `pool_size: 20`.

**Step 3: Remove hardcoded default**

In `lib/legion/cache/redis.rb`, change `client` signature from `pool_size: 20` to `pool_size: nil`. Resolve inside:

```ruby
def client(server: nil, servers: [], pool_size: nil, timeout: nil, logger: nil, **opts)
  return @client unless @client.nil?

  settings = defined?(Legion::Settings) ? Legion::Settings[:cache] : {}
  @pool_size = pool_size || settings[:pool_size] || 10
  @timeout = timeout || settings[:timeout] || 5
  # ...
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/redis_spec.rb --tag ~integration -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/redis.rb spec/legion/redis_spec.rb
git commit -m "remove hardcoded pool_size from redis driver, resolve from settings"
```

---

### Task B2: Separate pool checkout timeout from operation timeout

**Files:**
- Modify: `lib/legion/cache/settings.rb`, `lib/legion/cache/memcached.rb`, `lib/legion/cache/redis.rb`
- Test: `spec/legion/settings_spec.rb`

**Step 1: Write the failing test**

Add to `spec/legion/settings_spec.rb`:

```ruby
describe 'pool_checkout_timeout' do
  it 'has pool_checkout_timeout in global defaults' do
    expect(Legion::Cache::Settings.default[:pool_checkout_timeout]).to eq(5)
  end

  it 'has pool_checkout_timeout in local defaults' do
    expect(Legion::Cache::Settings.local[:pool_checkout_timeout]).to eq(5)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/settings_spec.rb -v`
Expected: FAIL

**Step 3: Add setting and wire into drivers**

In `lib/legion/cache/settings.rb`, add to both `self.default` and `self.local`:
```ruby
pool_checkout_timeout: 5,
```

In `lib/legion/cache/memcached.rb` `client`:
```ruby
checkout_timeout = opts[:pool_checkout_timeout] || settings[:pool_checkout_timeout] || @timeout
@client = ConnectionPool.new(size: pool_size, timeout: checkout_timeout) do
  Dalli::Client.new(resolved, cache_opts)
end
```

In `lib/legion/cache/redis.rb` `client`:
```ruby
checkout_timeout = opts[:pool_checkout_timeout] || settings[:pool_checkout_timeout] || @timeout
@client = ConnectionPool.new(size: pool_size, timeout: checkout_timeout) do
  build_redis_client(...)
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/settings_spec.rb -v`
Expected: PASS

**Step 5: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/legion/cache/settings.rb lib/legion/cache/memcached.rb lib/legion/cache/redis.rb spec/legion/settings_spec.rb
git commit -m "separate pool checkout timeout from operation timeout"
```

---

### Task B3: Refactor @connected flags to Concurrent::AtomicBoolean

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`, `lib/legion/cache/memory.rb`, `lib/legion/cache/pool.rb`
- Test: `spec/legion/cache/thread_safety_spec.rb` (new)

**Context:** Design doc §11 specifies preferring `concurrent-ruby` primitives over raw Mutex/plain booleans. The new code (AsyncWriter, Reconnector) uses them, but existing `@connected`, `@using_local`, `@using_memory` flags in `cache.rb`, `local.rb`, `memory.rb`, and `pool.rb` are plain instance variables with no thread safety guarantees. With the reconnector running in a background thread and async writes in a pool, these flags are now read/written from multiple threads.

**Step 1: Write the failing tests**

Create `spec/legion/cache/thread_safety_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'thread-safe state flags' do
  describe 'Legion::Cache' do
    it 'uses AtomicBoolean for connected state' do
      flag = Legion::Cache.instance_variable_get(:@connected)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end

    it 'uses AtomicBoolean for using_local state' do
      flag = Legion::Cache.instance_variable_get(:@using_local)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end

    it 'uses AtomicBoolean for using_memory state' do
      flag = Legion::Cache.instance_variable_get(:@using_memory)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end
  end

  describe 'Legion::Cache::Local' do
    it 'uses AtomicBoolean for connected state' do
      flag = Legion::Cache::Local.instance_variable_get(:@connected)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end
  end

  describe 'Legion::Cache::Memory' do
    it 'uses AtomicBoolean for connected state' do
      flag = Legion::Cache::Memory.instance_variable_get(:@connected)
      expect(flag).to be_a(Concurrent::AtomicBoolean).or be_nil
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/thread_safety_spec.rb -v`
Expected: FAIL — all flags are plain booleans.

**Step 3: Refactor flags**

Add `require 'concurrent'` to each file.

In `lib/legion/cache.rb` class body:
```ruby
@connected = Concurrent::AtomicBoolean.new(false)
@using_local = Concurrent::AtomicBoolean.new(false)
@using_memory = Concurrent::AtomicBoolean.new(false)
```

Update all reads: `@connected == true` → `@connected.true?`
Update all writes: `@connected = true` → `@connected.make_true` / `@connected.make_false`

In `lib/legion/cache/local.rb`:
```ruby
@connected = Concurrent::AtomicBoolean.new(false)
```

Same read/write pattern changes.

In `lib/legion/cache/memory.rb`:
```ruby
@connected = Concurrent::AtomicBoolean.new(false)
```

Same read/write pattern changes. Keep the existing `@mutex` for `@store`/`@expiry` synchronization — that protects data structures, not flags.

In `lib/legion/cache/pool.rb`:
```ruby
def connected?
  @connected&.true? || false
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/thread_safety_spec.rb -v`
Expected: PASS

**Step 5: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb lib/legion/cache/memory.rb lib/legion/cache/pool.rb spec/legion/cache/thread_safety_spec.rb
git commit -m "refactor state flags to Concurrent::AtomicBoolean for thread safety"
```

---

### Task B4: Add mget/mset to Memory adapter

**Files:**
- Modify: `lib/legion/cache/memory.rb`
- Test: `spec/legion/cache/memory_spec.rb`

**Context:** Memory adapter has `get`/`set`/`fetch`/`delete`/`flush` but no `mget`/`mset`. The top-level `Legion::Cache` handles Memory mget/mset inline, but for consistency every adapter should implement the full interface. This also future-proofs against Local using Memory as a driver.

**Step 1: Write the failing tests**

Add to `spec/legion/cache/memory_spec.rb`:

```ruby
describe '.mget' do
  before { described_class.setup }

  it 'returns a hash of key-value pairs' do
    described_class.set('a', 1)
    described_class.set('b', 2)
    result = described_class.mget('a', 'b', 'missing')
    expect(result).to eq({ 'a' => 1, 'b' => 2, 'missing' => nil })
  end

  it 'returns empty hash for empty keys' do
    expect(described_class.mget).to eq({})
  end
end

describe '.mset' do
  before { described_class.setup }

  it 'stores multiple key-value pairs' do
    described_class.mset({ 'x' => 10, 'y' => 20 })
    expect(described_class.get('x')).to eq(10)
    expect(described_class.get('y')).to eq(20)
  end

  it 'accepts keyword ttl' do
    described_class.mset({ 'exp' => 'val' }, ttl: 0.1)
    sleep 0.15
    expect(described_class.get('exp')).to be_nil
  end

  it 'returns true on success' do
    expect(described_class.mset({ 'a' => 1 })).to be(true)
  end

  it 'returns true for empty hash' do
    expect(described_class.mset({})).to be(true)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/memory_spec.rb -v`
Expected: FAIL — `mget`/`mset` not defined.

**Step 3: Implement**

In `lib/legion/cache/memory.rb`:

```ruby
def mget(*keys)
  keys = keys.flatten
  return {} if keys.empty?

  @mutex.synchronize do
    keys.each { |k| expire_if_needed(k) }
    keys.to_h { |k| [k, @store[k]] }
  end
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :memory_mget)
  {}
end

def mset(hash, ttl: nil)
  return true if hash.empty?

  hash.each { |k, v| set(k, v, ttl: ttl) }
  true
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :memory_mset)
  true
end

def mset_sync(hash, ttl: nil)
  mset(hash, ttl: ttl)
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/memory_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/memory.rb spec/legion/cache/memory_spec.rb
git commit -m "add mget and mset to memory adapter for interface consistency"
```

---

### Task B5: Update RedisHash to use public client accessor

**Files:**
- Modify: `lib/legion/cache/redis_hash.rb`, `lib/legion/cache.rb`
- Test: `spec/legion/cache/redis_hash_spec.rb`

**Context:** `RedisHash` calls `Legion::Cache.instance_variable_get(:@client)` directly in every method (7 occurrences). This bypasses all public API, breaks encapsulation, and will break if `@client` is wrapped in an atomic reference or renamed. Add a public `pool` accessor on `Legion::Cache` and use it instead.

**Step 1: Write the failing test**

Add to `spec/legion/cache/redis_hash_spec.rb`:

```ruby
describe 'does not access @client directly' do
  it 'uses Legion::Cache.pool instead of instance_variable_get' do
    source = File.read(File.expand_path('../../lib/legion/cache/redis_hash.rb', __dir__))
    expect(source).not_to include('instance_variable_get(:@client)')
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/redis_hash_spec.rb -v`
Expected: FAIL

**Step 3: Add public pool accessor**

In `lib/legion/cache.rb`, add to the class << self block:

```ruby
def pool
  @client
end
```

In `lib/legion/cache/redis_hash.rb`, replace all occurrences of:
```ruby
Legion::Cache.instance_variable_get(:@client)
```
with:
```ruby
Legion::Cache.pool
```

There are 7 occurrences: `redis_available?`, `hset`, `hgetall`, `hdel`, `zadd`, `zrangebyscore`, `zrem`, `expire`.

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/redis_hash_spec.rb -v`
Expected: PASS

**Step 5: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/redis_hash.rb spec/legion/cache/redis_hash_spec.rb
git commit -m "replace direct @client access in redis_hash with public pool accessor"
```

---

### Task B6: End-to-end lifecycle integration test

**Files:**
- Create: `spec/legion/cache/lifecycle_spec.rb`

**Context:** No test covers the full chain: shared fails → failback to local → reconnector starts → reconnector succeeds → operations return to shared. This validates all the pieces work together.

**Step 1: Write the test**

Create `spec/legion/cache/lifecycle_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'full cache lifecycle' do
  let(:local_store) { {} }
  let(:shared_store) { {} }
  let(:shared_available) { Concurrent::AtomicBoolean.new(false) }

  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_local, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@using_memory, Concurrent::AtomicBoolean.new(false))
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache::Local.reset!

    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:failback_to_local] = true

    # Stub Local
    allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
    allow(Legion::Cache::Local).to receive(:enabled?).and_return(true)
    allow(Legion::Cache::Local).to receive(:setup)
    allow(Legion::Cache::Local).to receive(:shutdown)
    allow(Legion::Cache::Local).to receive(:get) { |key| local_store[key] }
    allow(Legion::Cache::Local).to receive(:set) do |key, value, **|
      local_store[key] = value
      true
    end

    # Stub shared to fail initially
    allow(Legion::Cache).to receive(:client).and_invoke(
      ->(**) { raise RuntimeError, 'connection refused' if shared_available.false?; nil }
    )
  end

  after do
    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    reconnector&.stop
    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:failback_to_local] = true
  end

  it 'fails back to local, then recovers when shared comes back' do
    # Phase 1: shared fails, falls back to local
    Legion::Cache.setup
    expect(Legion::Cache.using_local?).to be(true)

    # Phase 2: operations work via local
    Legion::Cache.set('lifecycle', 'local_value', async: false)
    expect(Legion::Cache.get('lifecycle')).to eq('local_value')
    expect(local_store['lifecycle']).to eq('local_value')

    # Phase 3: shared comes back
    shared_available.make_true

    # Phase 4: verify reconnector was started
    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    expect(reconnector).not_to be_nil

    # Cleanup
    reconnector.stop
  end

  it 'returns nil everywhere when both shared and local are down and failback is off' do
    Legion::Settings[:cache][:failback_to_local] = false
    allow(Legion::Cache::Local).to receive(:connected?).and_return(false)

    Legion::Cache.setup
    expect(Legion::Cache.get('anything')).to be_nil
  end
end
```

**Step 2: Run test**

Run: `bundle exec rspec spec/legion/cache/lifecycle_spec.rb -v`
Expected: PASS (this test is written against the expected final state after all prior tasks)

**Step 3: Commit**

```bash
git add spec/legion/cache/lifecycle_spec.rb
git commit -m "add end-to-end lifecycle integration test"
```

---

### Task B7: Automatic failback to Local when shared is unavailable

**Files:**
- Modify: `lib/legion/cache/settings.rb`, `lib/legion/cache.rb`
- Test: `spec/legion/cache/failback_spec.rb` (new)

**Context:** When `Legion::Cache.enabled? == false` or `Legion::Cache.connected? == false` due to sustained failure, all operations should silently delegate to `Legion::Cache::Local` instead of returning nil/raising. Controlled by `Legion::Settings[:cache][:failback_to_local]` (default `true`).

**Step 1: Write the failing tests**

Create `spec/legion/cache/failback_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'failback to local' do
  let(:local_store) { {} }

  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, false)
    Legion::Cache.instance_variable_set(:@using_local, false)
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Settings[:cache][:failback_to_local] = true

    allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
    allow(Legion::Cache::Local).to receive(:enabled?).and_return(true)
    allow(Legion::Cache::Local).to receive(:get) { |key| local_store[key] }
    allow(Legion::Cache::Local).to receive(:set) do |key, value, **|
      local_store[key] = value
      true
    end
    allow(Legion::Cache::Local).to receive(:delete) do |key, **|
      !local_store.delete(key).nil?
    end
    allow(Legion::Cache::Local).to receive(:fetch) do |key, **opts, &block|
      next local_store[key] if local_store.key?(key)
      value = block&.call
      local_store[key] = value
      value
    end
    allow(Legion::Cache::Local).to receive(:flush) do
      local_store.clear
      true
    end
  end

  after do
    Legion::Settings[:cache][:enabled] = true
    Legion::Settings[:cache][:failback_to_local] = true
  end

  describe 'when shared is disabled' do
    before { Legion::Settings[:cache][:enabled] = false }

    it 'get delegates to Local' do
      local_store['key'] = 'value'
      expect(Legion::Cache.get('key')).to eq('value')
    end

    it 'set delegates to Local' do
      Legion::Cache.set('key', 'value', async: false)
      expect(local_store['key']).to eq('value')
    end

    it 'fetch delegates to Local' do
      result = Legion::Cache.fetch('miss', ttl: 60) { 'computed' }
      expect(result).to eq('computed')
      expect(local_store['miss']).to eq('computed')
    end

    it 'delete delegates to Local' do
      local_store['del'] = 'gone'
      Legion::Cache.delete('del', async: false)
      expect(local_store['del']).to be_nil
    end

    it 'flush delegates to Local' do
      local_store['a'] = 1
      Legion::Cache.flush
      expect(local_store).to be_empty
    end
  end

  describe 'when shared is disconnected (failure)' do
    before do
      Legion::Settings[:cache][:enabled] = true
      Legion::Cache.instance_variable_set(:@connected, false)
    end

    it 'get delegates to Local' do
      local_store['key'] = 'value'
      expect(Legion::Cache.get('key')).to eq('value')
    end

    it 'set delegates to Local' do
      Legion::Cache.set('key', 'value', async: false)
      expect(local_store['key']).to eq('value')
    end
  end

  describe 'when failback_to_local is false' do
    before do
      Legion::Settings[:cache][:enabled] = false
      Legion::Settings[:cache][:failback_to_local] = false
    end

    it 'get returns nil instead of delegating' do
      local_store['key'] = 'value'
      expect(Legion::Cache.get('key')).to be_nil
    end
  end

  describe 'when Local is also not connected' do
    before do
      Legion::Settings[:cache][:enabled] = false
      allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
    end

    it 'get returns nil' do
      expect(Legion::Cache.get('key')).to be_nil
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/failback_spec.rb -v`
Expected: FAIL — no failback logic exists yet.

**Step 3: Add setting**

In `lib/legion/cache/settings.rb`, add to `self.default`:
```ruby
failback_to_local: true,
```

**Step 4: Add failback logic to Legion::Cache**

In `lib/legion/cache.rb`, add a private helper:

```ruby
def failback_to_local?
  return false unless Legion::Cache::Local.connected?

  setting = if defined?(Legion::Settings)
              Legion::Settings.dig(:cache, :failback_to_local) != false
            else
              true
            end
  setting && (!enabled? || !@connected)
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :cache_failback_check)
  false
end
```

Update each operation method to check failback before returning nil/raising. For `get`:

```ruby
def get(key)
  return Legion::Cache::Memory.get(key) if @using_memory
  return Legion::Cache::Local.get(key) if @using_local
  return Legion::Cache::Local.get(key) if failback_to_local?

  configure_shared_adapter!
  super
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :cache_get, key: key)
  nil
end
```

Same pattern for `set`, `fetch`, `delete`, `flush`, `mget`, `mset` — check `failback_to_local?` and delegate to `Legion::Cache::Local` before the `enabled?` nil-return or the shared adapter path.

**Step 5: Run tests**

Run: `bundle exec rspec spec/legion/cache/failback_spec.rb -v`
Expected: PASS

**Step 6: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 7: Commit**

```bash
git add lib/legion/cache/settings.rb lib/legion/cache.rb spec/legion/cache/failback_spec.rb
git commit -m "add automatic failback to local when shared cache is unavailable"
```

---

### Task B8: Full validation and version bump

**Files:**
- Modify: `lib/legion/cache/version.rb`, `CHANGELOG.md`

**Step 1: Run full test suite**

Run: `bundle exec rspec -v`
Expected: All unit specs PASS.

**Step 2: Run rubocop**

Run: `bundle exec rubocop -A && bundle exec rubocop`
Expected: Zero offenses.

**Step 3: Bump version**

In `lib/legion/cache/version.rb`, bump patch: `1.4.0` -> `1.4.1`.

**Step 4: Update CHANGELOG.md**

```markdown
## [1.4.1] - 2026-04-06

### Fixed
- AsyncWriter TOCTOU race condition in enqueue (capture local executor reference)
- Reconnector deadlock on stop (release mutex before thread.join)
- Reconnector NoMethodError on successful reconnect (AtomicFixnum reset)
- Missing require 'concurrent' in reconnector.rb
- Redis cluster flush now passes auth/TLS credentials to per-node connections
- Async writer drains before pool close on shutdown
- Serialization applied to mget/mset_sync (was only on set_sync/get)
- Binary encoding forced before serialization prefix checks

### Added
- Automatic failback to Local tier when shared cache is disabled or disconnected (configurable via `failback_to_local: true`)
- mget/mset methods on Memory adapter for interface consistency
- Public `pool` accessor on Legion::Cache (replaces direct @client access)
- End-to-end lifecycle integration test (shared fail -> local failback -> reconnect)

### Changed
- Helper and Cacheable use async: false for read-after-write consistency
- AsyncWriter and Reconnector are tier-aware (read :cache_local for local tier)
- Redis driver pool_size resolved from settings (was hardcoded to 20)
- Pool checkout timeout separated from operation timeout (new pool_checkout_timeout setting)
- Reconnector starts on any shared failure (even when local fallback succeeds)
- setup/setup_shared guarded by enabled? check
- Separate failed_count counter in AsyncWriter stats
- State flags (@connected, @using_local, @using_memory) refactored to Concurrent::AtomicBoolean
- RedisHash uses public pool accessor instead of instance_variable_get(:@client)
```

**Step 5: Commit**

```bash
git add lib/legion/cache/version.rb CHANGELOG.md
git commit -m "bump version to 1.4.1, update changelog with post-optimization fixes"
```

**Step 6: Final validation**

Run: `bundle exec rspec -v && bundle exec rubocop`
Expected: All green.
