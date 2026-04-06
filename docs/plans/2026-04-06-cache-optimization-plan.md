# Legion::Cache Optimization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Normalize all Legion::Cache drivers and tiers to a uniform interface, add async writes, background reconnection, transparent serialization, and operational observability.

**Architecture:** Seven layered phases, each independently testable and committable. Phases 1-3 normalize the existing code. Phases 4-6 add new capabilities. Phase 7 wires everything together.

**Tech Stack:** Ruby >= 3.4, concurrent-ruby (ThreadPoolExecutor), Dalli, Redis, ConnectionPool, Legion::Logging, Legion::Settings

**Design doc:** `docs/plans/2026-04-06-cache-optimization-design.md`

---

### Task 1: Unify method signatures — Settings and defaults

**Files:**
- Modify: `lib/legion/cache/settings.rb`
- Test: `spec/legion/settings_spec.rb`

**Step 1: Write the failing test**

Add to `spec/legion/settings_spec.rb`:

```ruby
describe 'default TTL values' do
  it 'has global default_ttl of 3600' do
    expect(Legion::Cache::Settings.default[:default_ttl]).to eq(3600)
  end

  it 'has local default_ttl of 21600' do
    expect(Legion::Cache::Settings.local[:default_ttl]).to eq(21_600)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/settings_spec.rb -v`
Expected: FAIL — default_ttl is currently 60 for both.

**Step 3: Update settings defaults**

In `lib/legion/cache/settings.rb`, change `self.default`:
- `default_ttl: 3600` (was 60)

Change `self.local`:
- `default_ttl: 21_600` (was 60)

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/settings_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/settings.rb spec/legion/settings_spec.rb
git commit -m "update default TTL to 3600 global, 21600 local"
```

---

### Task 2: Unify method signatures — Memcached driver

**Files:**
- Modify: `lib/legion/cache/memcached.rb`
- Test: `spec/legion/memcached_spec.rb`

**Step 1: Write the failing tests**

Replace the existing `spec/legion/memcached_spec.rb` integration specs to validate the new signatures. Add these unit specs at the top (before the integration block):

```ruby
RSpec.describe Legion::Cache::Memcached do
  describe 'method signatures' do
    it 'set accepts keyword ttl' do
      cache = described_class.dup
      pool = instance_double(ConnectionPool)
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)

      dalli = instance_double(Dalli::Client)
      allow(pool).to receive(:with).and_yield(dalli)
      allow(dalli).to receive(:set).and_return(1)

      expect { cache.set('k', 'v', ttl: 120) }.not_to raise_error
    end

    it 'flush takes no arguments' do
      expect(described_class.method(:flush).arity).to eq(0)
    end

    it 'uses log instead of cache_logger' do
      expect(described_class.private_method_defined?(:cache_logger)).to be(false)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/memcached_spec.rb --tag ~integration -v`
Expected: FAIL — `set` doesn't accept keyword `ttl:`, `flush` has arity 1 (the `delay` param), `cache_logger` still exists.

**Step 3: Refactor Memcached driver**

In `lib/legion/cache/memcached.rb`:

1. Change `set(key, value, ttl = 180)` to `set_sync(key, value, ttl: nil)`. Resolve TTL inside: `ttl ||= default_ttl`. Add a public `set(key, value, ttl: nil, **opts)` that calls `set_sync`.
2. Change `get(key)` — remove the broken `result[0]` / `Legion::JSON.dump` logic. Dalli handles serialization via its `serializer` option already. Just return the result.
3. Change `fetch(key, ttl = nil, &)` to `fetch(key, ttl: nil, &)`. Same JSON fix as get.
4. Change `delete(key)` to `delete_sync(key)`. Add public `delete(key, **opts)` that calls `delete_sync`.
5. Change `flush(delay = 0)` to `flush`. Remove delay param. Call `conn.flush.first` with no args.
6. Change `mset(hash)` to `mset_sync(hash, ttl: nil)`. Add public `mset(hash, ttl: nil, **opts)`.
7. Change `client` kwargs to match the unified signature: `client(server: nil, servers: [], pool_size: nil, timeout: nil, username: nil, password: nil, logger: nil, **opts)`.
8. Remove `cache_logger` and `shared_dalli_logger` private methods. Replace all calls with `log`.
9. Set Dalli logger to `log` directly.
10. Add `default_ttl` private method: reads `Legion::Settings.dig(:cache, :default_ttl) || 3600`.

**Step 4: Run all memcached specs**

Run: `bundle exec rspec spec/legion/memcached_spec.rb --tag ~integration -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/memcached.rb spec/legion/memcached_spec.rb
git commit -m "unify memcached driver method signatures"
```

---

### Task 3: Unify method signatures — Redis driver

**Files:**
- Modify: `lib/legion/cache/redis.rb`
- Test: `spec/legion/redis_spec.rb`

**Step 1: Write the failing tests**

Add unit specs to `spec/legion/redis_spec.rb`:

```ruby
RSpec.describe Legion::Cache::Redis do
  describe 'method signatures' do
    it 'set accepts keyword ttl' do
      cache = described_class.dup
      pool = instance_double(ConnectionPool)
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)

      redis = instance_double(Redis)
      allow(pool).to receive(:with).and_yield(redis)
      allow(redis).to receive(:set).and_return('OK')

      expect { cache.set('k', 'v', ttl: 120) }.not_to raise_error
    end

    it 'fetch accepts keyword ttl' do
      cache = described_class.dup
      pool = instance_double(ConnectionPool)
      cache.instance_variable_set(:@client, pool)
      cache.instance_variable_set(:@connected, true)

      redis = instance_double(Redis)
      allow(pool).to receive(:with).and_yield(redis)
      allow(redis).to receive(:get).and_return('val')

      expect { cache.fetch('k', ttl: 60) }.not_to raise_error
    end

    it 'flush takes no arguments' do
      expect(described_class.method(:flush).arity).to eq(0)
    end

    it 'uses log instead of cache_logger' do
      expect(described_class.private_method_defined?(:cache_logger)).to be(false)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/redis_spec.rb --tag ~integration -v`
Expected: FAIL

**Step 3: Refactor Redis driver**

In `lib/legion/cache/redis.rb`:

1. Change `set(key, value, ttl = nil)` to `set_sync(key, value, ttl: nil)`. Resolve TTL: `ttl ||= default_ttl`. Add public `set(key, value, ttl: nil, **opts)`.
2. Change `fetch(key, ttl = nil)` to `fetch(key, ttl: nil)`.
3. Change `delete(key)` to `delete_sync(key)`. Add public `delete(key, **opts)`.
4. Change `flush` — already takes no args for Redis non-cluster. Keep as `flush`. No change needed.
5. Change `mset(hash)` to `mset_sync(hash, ttl: nil)`. Add public `mset(hash, ttl: nil, **opts)`.
6. Normalize `client` kwargs: `client(server: nil, servers: [], pool_size: nil, timeout: nil, username: nil, password: nil, logger: nil, **opts)`. Move `cluster`, `replica`, `fixed_hostname`, `db`, `reconnect_attempts` into `**opts` extraction.
7. Remove `cache_logger` private method. Replace with `log`.
8. Change all `rescue ::Redis::BaseError` to `rescue StandardError`.
9. Remove `log_cluster_error` — inline `handle_exception` calls.
10. Add `default_ttl` private method: reads `Legion::Settings.dig(:cache, :default_ttl) || 3600`.

**Step 4: Run all redis specs**

Run: `bundle exec rspec spec/legion/redis_spec.rb --tag ~integration -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/redis.rb spec/legion/redis_spec.rb
git commit -m "unify redis driver method signatures"
```

---

### Task 4: Unify method signatures — Memory adapter

**Files:**
- Modify: `lib/legion/cache/memory.rb`
- Test: `spec/legion/cache/memory_spec.rb`

**Step 1: Write the failing tests**

Add to `spec/legion/cache/memory_spec.rb`:

```ruby
describe 'keyword ttl' do
  before { described_class.setup }

  it 'accepts ttl as keyword arg on set' do
    described_class.set('kw', 'val', ttl: 300)
    expect(described_class.get('kw')).to eq('val')
  end

  it 'accepts ttl as keyword arg on fetch' do
    result = described_class.fetch('fkw', ttl: 300) { 'fetched' }
    expect(result).to eq('fetched')
  end
end

describe 'flush takes no arguments' do
  it 'has arity 0' do
    expect(described_class.method(:flush).arity).to eq(0)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/memory_spec.rb -v`
Expected: FAIL — set/fetch don't accept keyword ttl, flush has arity accepting `_delay`.

**Step 3: Refactor Memory adapter**

In `lib/legion/cache/memory.rb`:

1. Change `set(key, value, ttl = nil)` to `set_sync(key, value, ttl: nil)`. Add public `set(key, value, ttl: nil, **opts)` that calls `set_sync`.
2. Change `fetch(key, ttl = nil)` to `fetch(key, ttl: nil, &block)`.
3. Change `flush(_delay = 0)` to `flush`.
4. Add `delete_sync(key)` (rename current `delete`). Add public `delete(key, **opts)`.
5. Add `default_ttl` returning `3600`.

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/cache/memory_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/memory.rb spec/legion/cache/memory_spec.rb
git commit -m "unify memory adapter method signatures"
```

---

### Task 5: Unify method signatures — Local tier

**Files:**
- Modify: `lib/legion/cache/local.rb`
- Test: `spec/legion/local_spec.rb`

**Step 1: Write the failing tests**

Add to the unit spec section of `spec/legion/local_spec.rb`:

```ruby
describe 'method signatures' do
  it 'responds to enabled?' do
    expect(described_class).to respond_to(:enabled?)
  end

  it 'set accepts keyword ttl' do
    driver = double('driver')
    allow(driver).to receive(:set_sync)
    described_class.instance_variable_set(:@driver, driver)
    described_class.instance_variable_set(:@connected, true)
    expect { described_class.set('k', 'v', ttl: 120) }.not_to raise_error
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/local_spec.rb --tag ~integration -v`
Expected: FAIL

**Step 3: Refactor Local tier**

In `lib/legion/cache/local.rb`:

1. Change `set(key, value, ttl = 180)` to `set(key, value, ttl: nil, async: true, phi: false)`. Resolve TTL: `ttl ||= local_default_ttl`. Delegate to `set_sync` or `set_async`.
2. Add `set_sync(key, value, ttl:)`, `set_async(key, value, ttl:)`.
3. Change `fetch(key, ttl = nil, &)` to `fetch(key, ttl: nil, &)`. Remove the broken JSON dump logic (same bug as Memcached get — checking `result[0]` before nil check).
4. Change `delete(key)` to `delete(key, async: true)` with sync/async delegation.
5. Change `flush(delay = 0)` to `flush`.
6. Add `mget(*keys)` and `mset(hash, ttl: nil, async: true)`.
7. Add `local_default_ttl` private method: reads `Legion::Settings.dig(:cache_local, :default_ttl) || 21_600`.

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/local_spec.rb --tag ~integration -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/local.rb spec/legion/local_spec.rb
git commit -m "unify local tier method signatures"
```

---

### Task 6: Unify method signatures — Top-level Legion::Cache

**Files:**
- Modify: `lib/legion/cache.rb`
- Test: `spec/legion/cache_spec.rb`, `spec/legion/cache_interface_spec.rb`, `spec/legion/cache_fallback_spec.rb`

**Step 1: Write the failing tests**

Add to `spec/legion/cache_interface_spec.rb`:

```ruby
it 'set accepts keyword ttl and async' do
  params = Legion::Cache.method(:set).parameters
  names = params.map(&:last)
  expect(names).to include(:ttl)
  expect(names).to include(:async)
end

it 'delete accepts keyword async' do
  params = Legion::Cache.method(:delete).parameters
  names = params.map(&:last)
  expect(names).to include(:async)
end

it 'flush takes no arguments' do
  expect(Legion::Cache.method(:flush).arity).to eq(0)
end

it 'responds to enabled?' do
  expect(Legion::Cache).to respond_to(:enabled?)
end
```

Update `spec/legion/cache_fallback_spec.rb` stubs to use new keyword signatures:
- Change `allow(Legion::Cache::Local).to receive(:set) do |key, value, _ttl|` to `do |key, value, ttl: nil, **|`
- Change `allow(Legion::Cache::Local).to receive(:fetch) do |key, _ttl, &block|` to `do |key, ttl: nil, &block|`
- Change `allow(Legion::Cache::Local).to receive(:flush) do |_delay = 0|` to `do`

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache_interface_spec.rb spec/legion/cache_fallback_spec.rb -v`
Expected: FAIL

**Step 3: Refactor top-level module**

In `lib/legion/cache.rb`:

1. Change `set(key, value, ttl = nil, **opts)` to `set(key, value, ttl: nil, async: true, phi: false)`. Resolve TTL from settings, enforce PHI, delegate to `set_sync`/`set_async`.
2. Add `set_sync(key, value, ttl:)`, `set_async(key, value, ttl:)`.
3. Change `fetch(key, ttl = nil, &)` to `fetch(key, ttl: nil, &)`.
4. Change `delete(key)` to `delete(key, async: true)` with sync/async delegation.
5. Change `flush(delay = 0)` to `flush`.
6. Change `mget(*keys)` — keep as is, signature is fine.
7. Change `mset(hash)` to `mset(hash, ttl: nil, async: true)`.
8. Delegation to Memory/Local adapters must use the new keyword signatures.

**Step 4: Run full spec suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS (all unit specs green)

**Step 5: Commit**

```bash
git add lib/legion/cache.rb spec/legion/cache_spec.rb spec/legion/cache_interface_spec.rb spec/legion/cache_fallback_spec.rb
git commit -m "unify top-level cache method signatures"
```

---

### Task 7: Exception handling — All drivers

**Files:**
- Modify: `lib/legion/cache/memcached.rb`, `lib/legion/cache/redis.rb`, `lib/legion/cache/memory.rb`
- Test: `spec/legion/cache/exception_handling_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/exception_handling_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memory'

RSpec.describe 'exception handling' do
  describe Legion::Cache::Memory do
    before { described_class.setup }
    after { described_class.reset! }

    describe 'reads return nil on error' do
      it 'get returns nil when store raises' do
        described_class.instance_variable_get(:@store)
        allow(described_class).to receive(:expire_if_needed).and_raise(RuntimeError, 'boom')
        expect(described_class.get('key')).to be_nil
      end
    end

    describe 'sync writes re-raise' do
      it 'set_sync raises on error' do
        allow(described_class.instance_variable_get(:@mutex)).to receive(:synchronize).and_raise(RuntimeError, 'boom')
        expect { described_class.set_sync('k', 'v', ttl: 60) }.to raise_error(RuntimeError, 'boom')
      end
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/exception_handling_spec.rb -v`
Expected: FAIL — `set_sync` not defined yet (from Task 4), or exception behavior doesn't match.

**Step 3: Add exception handling to all drivers**

For each driver (`memcached.rb`, `redis.rb`, `memory.rb`):

**Reads** (`get`, `fetch`, `mget`):
```ruby
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :<driver>_get, key: key)
  nil # or {} for mget
```

**Sync writes** (`set_sync`, `delete_sync`, `mset_sync`):
```ruby
rescue StandardError => e
  handle_exception(e, level: :error, handled: false, operation: :<driver>_set_sync, key: key)
  raise e
```

**Lifecycle** (`client`, `close`, `restart`):
```ruby
rescue StandardError => e
  handle_exception(e, level: :error, handled: true, operation: :<driver>_client)
  @connected = false
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/exception_handling_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/memcached.rb lib/legion/cache/redis.rb lib/legion/cache/memory.rb spec/legion/cache/exception_handling_spec.rb
git commit -m "add uniform exception handling across all drivers"
```

---

### Task 8: Exception handling — Local tier and top-level

**Files:**
- Modify: `lib/legion/cache/local.rb`, `lib/legion/cache.rb`
- Test: `spec/legion/cache/exception_handling_spec.rb` (append)

**Step 1: Write the failing tests**

Append to `spec/legion/cache/exception_handling_spec.rb`:

```ruby
RSpec.describe 'Legion::Cache top-level exception handling' do
  before do
    ENV['LEGION_MODE'] = 'lite'
    Legion::Cache::Memory.setup
    Legion::Cache.instance_variable_set(:@using_memory, true)
    Legion::Cache.instance_variable_set(:@connected, true)
  end

  after do
    ENV.delete('LEGION_MODE')
    Legion::Cache::Memory.reset!
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@connected, false)
  end

  it 'get returns nil on internal error' do
    allow(Legion::Cache::Memory).to receive(:get).and_raise(RuntimeError, 'boom')
    expect(Legion::Cache.get('key')).to be_nil
  end

  it 'set_sync re-raises on error' do
    allow(Legion::Cache::Memory).to receive(:set_sync).and_raise(RuntimeError, 'boom')
    expect { Legion::Cache.set_sync('k', 'v', ttl: 60) }.to raise_error(RuntimeError, 'boom')
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/exception_handling_spec.rb -v`
Expected: FAIL

**Step 3: Add exception handling to Local and top-level**

Apply the same exception model to `lib/legion/cache/local.rb` and `lib/legion/cache.rb`:
- Reads: handled, return nil
- Sync writes: not handled, re-raise
- Lifecycle: handled, set `@connected = false`

**Step 4: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/local.rb lib/legion/cache.rb spec/legion/cache/exception_handling_spec.rb
git commit -m "add exception handling to local tier and top-level cache"
```

---

### Task 9: Transparent JSON serialization — Redis driver

**Files:**
- Modify: `lib/legion/cache/redis.rb`
- Test: `spec/legion/cache/redis_serialization_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/redis_serialization_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'

RSpec.describe 'Redis transparent serialization' do
  let(:cache) { Legion::Cache::Redis.dup }
  let(:pool) { instance_double(ConnectionPool) }
  let(:redis) { instance_double(Redis) }

  before do
    cache.instance_variable_set(:@client, pool)
    cache.instance_variable_set(:@connected, true)
    allow(pool).to receive(:with).and_yield(redis)
  end

  describe 'set_sync serializes complex types' do
    it 'prefixes strings with S' do
      expect(redis).to receive(:set).with('k', "S\x00hello", any_args).and_return('OK')
      cache.set_sync('k', 'hello', ttl: 60)
    end

    it 'prefixes hashes with J and JSON-encodes' do
      expect(redis).to receive(:set).with('k', /\AJ\x00/, any_args).and_return('OK')
      cache.set_sync('k', { foo: 'bar' }, ttl: 60)
    end

    it 'prefixes arrays with J and JSON-encodes' do
      expect(redis).to receive(:set).with('k', /\AJ\x00/, any_args).and_return('OK')
      cache.set_sync('k', [1, 2, 3], ttl: 60)
    end
  end

  describe 'get deserializes based on prefix' do
    it 'returns plain string for S prefix' do
      allow(redis).to receive(:get).and_return("S\x00hello")
      expect(cache.get('k')).to eq('hello')
    end

    it 'returns parsed hash for J prefix' do
      json = Legion::JSON.dump({ foo: 'bar' })
      allow(redis).to receive(:get).and_return("J\x00#{json}")
      result = cache.get('k')
      expect(result).to be_a(Hash)
      expect(result[:foo] || result['foo']).to eq('bar')
    end

    it 'returns raw string for legacy data without prefix' do
      allow(redis).to receive(:get).and_return('legacy_value')
      expect(cache.get('k')).to eq('legacy_value')
    end

    it 'returns raw string when JSON parse fails' do
      allow(redis).to receive(:get).and_return("J\x00not-valid-json{{{")
      expect(cache.get('k')).to eq("J\x00not-valid-json{{{")
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/redis_serialization_spec.rb -v`
Expected: FAIL — no prefix serialization exists yet.

**Step 3: Implement serialization**

In `lib/legion/cache/redis.rb`, add private methods:

```ruby
SERIALIZE_STRING = "S\x00".b.freeze
SERIALIZE_JSON   = "J\x00".b.freeze

def serialize_value(value)
  case value
  when String
    "#{SERIALIZE_STRING}#{value}"
  else
    "#{SERIALIZE_JSON}#{Legion::JSON.dump(value)}"
  end
end

def deserialize_value(raw)
  return nil if raw.nil?

  if raw.start_with?(SERIALIZE_JSON)
    Legion::JSON.load(raw.byteslice(2..))
  elsif raw.start_with?(SERIALIZE_STRING)
    raw.byteslice(2..)
  else
    raw # legacy data, no prefix
  end
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :redis_deserialize)
  raw
end
```

Wire `serialize_value` into `set_sync` and `deserialize_value` into `get`.

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/redis_serialization_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/redis.rb spec/legion/cache/redis_serialization_spec.rb
git commit -m "add transparent JSON serialization for redis driver"
```

---

### Task 10: Add `enabled?` and `connected?` — both tiers

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`, `lib/legion/cache/memory.rb`
- Test: `spec/legion/cache/enabled_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/enabled_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'enabled? and connected?' do
  before do
    Legion::Cache.instance_variable_set(:@connected, false)
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@using_local, false)
    Legion::Cache::Local.reset!
  end

  describe 'Legion::Cache.enabled?' do
    it 'returns true when settings enabled is true' do
      Legion::Settings[:cache][:enabled] = true
      expect(Legion::Cache.enabled?).to be(true)
    end

    it 'returns false when settings enabled is false' do
      Legion::Settings[:cache][:enabled] = false
      expect(Legion::Cache.enabled?).to be(false)
    end
  end

  describe 'Legion::Cache::Local.enabled?' do
    it 'reads from cache_local settings' do
      Legion::Settings[:cache_local] ||= {}
      Legion::Settings[:cache_local][:enabled] = false
      expect(Legion::Cache::Local.enabled?).to be(false)
    end
  end

  describe 'when disabled' do
    before { Legion::Settings[:cache][:enabled] = false }
    after { Legion::Settings[:cache][:enabled] = true }

    it 'connected? returns false even if @connected is true' do
      Legion::Cache.instance_variable_set(:@connected, true)
      expect(Legion::Cache.connected?).to be(false)
    end

    it 'get returns nil' do
      expect(Legion::Cache.get('anything')).to be_nil
    end

    it 'set with async: true returns true (no-op)' do
      expect(Legion::Cache.set('k', 'v', async: true)).to be(true)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/enabled_spec.rb -v`
Expected: FAIL

**Step 3: Implement enabled?**

In `lib/legion/cache.rb`:
```ruby
def enabled?
  return true unless defined?(Legion::Settings)

  Legion::Settings.dig(:cache, :enabled) != false
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :cache_enabled)
  true
end

def connected?
  return false unless enabled?

  @connected == true
end
```

Guard all operations: `return nil unless enabled?` at top of `get`, `fetch`, `mget`. For writes: `return true unless enabled?` for async, raise for sync.

Same pattern in `lib/legion/cache/local.rb` reading from `:cache_local`.

In `lib/legion/cache/memory.rb` add `enabled?` returning `true` always (memory adapter is always available in lite mode).

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/enabled_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb lib/legion/cache/memory.rb spec/legion/cache/enabled_spec.rb
git commit -m "add enabled? guard to both cache tiers"
```

---

### Task 11: Add `stats` method — both tiers

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/stats_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/stats_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'stats' do
  describe 'Legion::Cache.stats' do
    before do
      ENV['LEGION_MODE'] = 'lite'
      Legion::Cache.setup
    end

    after do
      Legion::Cache.shutdown
      ENV.delete('LEGION_MODE')
    end

    it 'returns a hash with required keys' do
      stats = Legion::Cache.stats
      expect(stats).to be_a(Hash)
      expect(stats).to include(
        :driver, :servers, :enabled, :connected,
        :using_local, :using_memory,
        :pool_size, :pool_available,
        :async_pool_size, :async_queue_depth, :async_processed,
        :reconnect_attempts, :uptime
      )
    end

    it 'returns a frozen hash' do
      expect(Legion::Cache.stats).to be_frozen
    end

    it 'reports correct driver' do
      expect(Legion::Cache.stats[:driver]).to eq('memory')
    end
  end

  describe 'Legion::Cache::Local.stats' do
    before { Legion::Cache::Local.reset! }

    it 'responds to stats' do
      expect(Legion::Cache::Local).to respond_to(:stats)
    end

    it 'returns a hash with required keys' do
      stats = Legion::Cache::Local.stats
      expect(stats).to include(:driver, :servers, :enabled, :connected)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/stats_spec.rb -v`
Expected: FAIL — `stats` method doesn't exist.

**Step 3: Implement stats**

In `lib/legion/cache.rb`:
```ruby
def stats
  {
    driver: driver_name,
    servers: resolved_servers,
    enabled: enabled?,
    connected: connected?,
    using_local: using_local?,
    using_memory: using_memory?,
    pool_size: safe_pool_size,
    pool_available: safe_pool_available,
    async_pool_size: async_writer_pool_size,
    async_queue_depth: async_writer_queue_depth,
    async_processed: async_writer_processed_count,
    reconnect_attempts: reconnector_attempts,
    uptime: uptime_seconds
  }.freeze
rescue StandardError => e
  handle_exception(e, level: :warn, handled: true, operation: :cache_stats)
  { error: e.message }.freeze
end
```

Track `@setup_at = Time.now` in `setup`. Add private helpers for safe pool queries (return 0 when not connected). Async/reconnect stats return 0 for now — they'll be wired in Tasks 13-14.

Same pattern for `Legion::Cache::Local.stats` (without `using_local`/`using_memory`).

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/stats_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/stats_spec.rb
git commit -m "add stats method to both cache tiers"
```

---

### Task 12: Add `concurrent-ruby` dependency

**Files:**
- Modify: `legion-cache.gemspec`

**Step 1: Add dependency**

In `legion-cache.gemspec`, add:
```ruby
spec.add_dependency 'concurrent-ruby', '>= 1.2'
```

**Step 2: Verify bundle resolves**

Run: `bundle install`
Expected: resolves successfully (concurrent-ruby already installed as transitive dep).

**Step 3: Commit**

```bash
git add legion-cache.gemspec
git commit -m "add concurrent-ruby dependency for async writer"
```

---

### Task 13: AsyncWriter

**Files:**
- Create: `lib/legion/cache/async_writer.rb`
- Test: `spec/legion/cache/async_writer_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/async_writer_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/async_writer'

RSpec.describe Legion::Cache::AsyncWriter do
  subject(:writer) { described_class.new }

  after { writer.stop(timeout: 2) if writer.running? }

  describe '#start' do
    it 'starts the thread pool' do
      writer.start
      expect(writer.running?).to be(true)
    end

    it 'is idempotent' do
      writer.start
      writer.start
      expect(writer.running?).to be(true)
    end
  end

  describe '#stop' do
    it 'drains pending work within timeout' do
      writer.start
      completed = Concurrent::AtomicBoolean.new(false)
      writer.enqueue { completed.make_true }
      writer.stop(timeout: 5)
      expect(completed.value).to be(true)
      expect(writer.running?).to be(false)
    end
  end

  describe '#enqueue' do
    it 'executes the block asynchronously' do
      writer.start
      result = Concurrent::AtomicReference.new(nil)
      writer.enqueue { result.set('done') }
      sleep 0.1
      expect(result.get).to eq('done')
    end

    it 'increments processed_count' do
      writer.start
      3.times { writer.enqueue { nil } }
      sleep 0.2
      expect(writer.processed_count).to eq(3)
    end

    it 'falls back to synchronous when pool is not running' do
      result = nil
      writer.enqueue { result = 'sync_fallback' }
      expect(result).to eq('sync_fallback')
    end
  end

  describe '#pool_size' do
    it 'returns configured pool size' do
      writer.start(pool_size: 2)
      expect(writer.pool_size).to eq(2)
    end
  end

  describe '#queue_depth' do
    it 'returns 0 when idle' do
      writer.start
      sleep 0.05
      expect(writer.queue_depth).to eq(0)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb -v`
Expected: FAIL — file doesn't exist.

**Step 3: Implement AsyncWriter**

Create `lib/legion/cache/async_writer.rb`:

```ruby
# frozen_string_literal: true

require 'concurrent-ruby'
require 'legion/logging/helper'

module Legion
  module Cache
    class AsyncWriter
      include Legion::Logging::Helper

      DEFAULT_POOL_SIZE = 4
      DEFAULT_QUEUE_SIZE = 1000
      DEFAULT_SHUTDOWN_TIMEOUT = 5

      def initialize(pool_size: nil, queue_size: nil, shutdown_timeout: nil)
        @config_pool_size = pool_size
        @config_queue_size = queue_size
        @config_shutdown_timeout = shutdown_timeout
        @processed = Concurrent::AtomicFixnum.new(0)
        @executor = nil
        @mutex = Mutex.new
      end

      def start(pool_size: nil, queue_size: nil, **)
        @mutex.synchronize do
          return if running?

          ps = pool_size || @config_pool_size || configured_pool_size
          qs = queue_size || @config_queue_size || configured_queue_size

          @executor = Concurrent::ThreadPoolExecutor.new(
            min_threads: 1,
            max_threads: ps,
            max_queue: qs,
            fallback_policy: :caller_runs
          )
          log.info "Legion::Cache::AsyncWriter started pool_size=#{ps} queue_size=#{qs}"
        end
      end

      def stop(timeout: nil)
        @mutex.synchronize do
          return unless @executor

          to = timeout || @config_shutdown_timeout || configured_shutdown_timeout
          @executor.shutdown
          unless @executor.wait_for_termination(to)
            @executor.kill
            log.warn "Legion::Cache::AsyncWriter force-killed after #{to}s timeout"
          end
          log.info "Legion::Cache::AsyncWriter stopped processed=#{@processed.value}"
          @executor = nil
        end
      end

      def enqueue(&block)
        if running?
          @executor.post do
            block.call
            @processed.increment
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: :async_writer_job)
            @processed.increment
          end
        else
          block.call
          @processed.increment
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :async_writer_sync_fallback)
          @processed.increment
        end
      end

      def running?
        @executor&.running? == true
      end

      def pool_size
        @executor&.max_length || 0
      end

      def queue_depth
        @executor&.queue_length || 0
      end

      def processed_count
        @processed.value
      end

      private

      def configured_pool_size
        return DEFAULT_POOL_SIZE unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :async, :pool_size) || DEFAULT_POOL_SIZE
      rescue StandardError
        DEFAULT_POOL_SIZE
      end

      def configured_queue_size
        return DEFAULT_QUEUE_SIZE unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :async, :queue_size) || DEFAULT_QUEUE_SIZE
      rescue StandardError
        DEFAULT_QUEUE_SIZE
      end

      def configured_shutdown_timeout
        return DEFAULT_SHUTDOWN_TIMEOUT unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :async, :shutdown_timeout) || DEFAULT_SHUTDOWN_TIMEOUT
      rescue StandardError
        DEFAULT_SHUTDOWN_TIMEOUT
      end
    end
  end
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/async_writer_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/async_writer.rb spec/legion/cache/async_writer_spec.rb
git commit -m "add async writer with concurrent-ruby thread pool"
```

---

### Task 14: Wire AsyncWriter into Cache and Local

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/async_integration_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/async_integration_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'async write integration' do
  before do
    ENV['LEGION_MODE'] = 'lite'
    Legion::Cache.setup
  end

  after do
    Legion::Cache.shutdown
    ENV.delete('LEGION_MODE')
  end

  it 'set with async: true returns true immediately' do
    expect(Legion::Cache.set('async_key', 'val', async: true)).to be(true)
  end

  it 'set with async: false writes synchronously' do
    Legion::Cache.set('sync_key', 'val', async: false)
    expect(Legion::Cache.get('sync_key')).to eq('val')
  end

  it 'set with async: true eventually writes the value' do
    Legion::Cache.set('eventual', 'val', async: true)
    sleep 0.2
    expect(Legion::Cache.get('eventual')).to eq('val')
  end

  it 'stats reports async pool size' do
    stats = Legion::Cache.stats
    expect(stats[:async_pool_size]).to be_a(Integer)
    expect(stats[:async_pool_size]).to be > 0
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/async_integration_spec.rb -v`
Expected: FAIL — async writer not wired in yet.

**Step 3: Wire in AsyncWriter**

In `lib/legion/cache.rb`:
- Add `require 'legion/cache/async_writer'`
- Create `@async_writer = Legion::Cache::AsyncWriter.new` in class body
- In `setup`: call `@async_writer.start`
- In `shutdown`: call `@async_writer.stop(timeout: configured_shutdown_timeout)`
- In `set_async`: `@async_writer.enqueue { set_sync(key, value, ttl: ttl) }`; return `true`
- In `delete_async`: `@async_writer.enqueue { delete_sync(key) }`; return `true`
- In `mset_async`: `@async_writer.enqueue { mset_sync(hash, ttl: ttl) }`; return `true`
- Wire stats: `async_writer_pool_size` returns `@async_writer.pool_size`, etc.

Same for `lib/legion/cache/local.rb` — its own `AsyncWriter` instance.

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/async_integration_spec.rb -v`
Expected: PASS

**Step 5: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/async_integration_spec.rb
git commit -m "wire async writer into cache and local tiers"
```

---

### Task 15: Reconnector

**Files:**
- Create: `lib/legion/cache/reconnector.rb`
- Test: `spec/legion/cache/reconnector_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/reconnector_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/reconnector'

RSpec.describe Legion::Cache::Reconnector do
  let(:connect_called) { Concurrent::AtomicFixnum.new(0) }
  let(:connect_block) { -> { connect_called.increment; raise 'nope' } }
  let(:enabled_block) { -> { true } }

  subject(:reconnector) do
    described_class.new(
      tier: :shared,
      connect_block: connect_block,
      enabled_block: enabled_block
    )
  end

  after { reconnector.stop }

  describe '#start' do
    it 'starts a reconnect loop' do
      reconnector.start
      expect(reconnector.running?).to be(true)
    end

    it 'is idempotent' do
      reconnector.start
      reconnector.start
      expect(reconnector.running?).to be(true)
    end
  end

  describe '#stop' do
    it 'stops the reconnect loop' do
      reconnector.start
      reconnector.stop
      expect(reconnector.running?).to be(false)
    end
  end

  describe 'exponential backoff' do
    it 'attempts reconnection with backoff' do
      reconnector.start
      sleep 1.5
      reconnector.stop
      expect(connect_called.value).to be >= 1
    end

    it 'tracks attempt count' do
      reconnector.start
      sleep 1.5
      reconnector.stop
      expect(reconnector.attempts).to be >= 1
    end
  end

  describe 'successful reconnect' do
    let(:connect_block) { -> { connect_called.increment } }

    it 'stops after successful reconnect' do
      reconnector.start
      sleep 1.5
      expect(reconnector.running?).to be(false)
      expect(connect_called.value).to eq(1)
    end

    it 'resets attempts after success' do
      reconnector.start
      sleep 1.5
      expect(reconnector.attempts).to eq(0)
    end
  end

  describe 'respects enabled?' do
    let(:enabled_block) { -> { false } }

    it 'does not attempt reconnect when disabled' do
      reconnector.start
      sleep 1.5
      expect(connect_called.value).to eq(0)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/reconnector_spec.rb -v`
Expected: FAIL — file doesn't exist.

**Step 3: Implement Reconnector**

Create `lib/legion/cache/reconnector.rb`:

```ruby
# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Cache
    class Reconnector
      include Legion::Logging::Helper

      DEFAULT_INITIAL_DELAY = 1
      DEFAULT_MAX_DELAY = 60

      def initialize(tier:, connect_block:, enabled_block:)
        @tier = tier
        @connect_block = connect_block
        @enabled_block = enabled_block
        @attempts = Concurrent::AtomicFixnum.new(0)
        @thread = nil
        @mutex = Mutex.new
        @stop_signal = false
      end

      def start
        @mutex.synchronize do
          return if running?

          @stop_signal = false
          @thread = Thread.new { reconnect_loop }
          log.info "Legion::Cache::Reconnector[#{@tier}] started"
        end
      end

      def stop
        @mutex.synchronize do
          @stop_signal = true
          @thread&.join(5)
          @thread = nil
          log.info "Legion::Cache::Reconnector[#{@tier}] stopped"
        end
      end

      def running?
        @thread&.alive? == true
      end

      def attempts
        @attempts.value
      end

      def next_retry_at
        @next_retry_at
      end

      private

      def reconnect_loop
        delay = configured_initial_delay

        until @stop_signal
          unless @enabled_block.call
            sleep 1
            next
          end

          begin
            @next_retry_at = Time.now + delay
            sleep delay
            return if @stop_signal

            @connect_block.call
            @attempts.value = 0
            @next_retry_at = nil
            log.info "Legion::Cache::Reconnector[#{@tier}] reconnected after #{@attempts.value} attempts"
            return
          rescue StandardError => e
            @attempts.increment
            handle_exception(e, level: :warn, handled: true,
                             operation: :"reconnector_#{@tier}",
                             attempt: @attempts.value, next_delay: delay)
            delay = [delay * 2, configured_max_delay].min
          end
        end
      rescue StandardError => e
        handle_exception(e, level: :error, handled: true, operation: :"reconnector_#{@tier}_loop")
      end

      def configured_initial_delay
        return DEFAULT_INITIAL_DELAY unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :reconnect, :initial_delay) || DEFAULT_INITIAL_DELAY
      rescue StandardError
        DEFAULT_INITIAL_DELAY
      end

      def configured_max_delay
        return DEFAULT_MAX_DELAY unless defined?(Legion::Settings)

        Legion::Settings.dig(:cache, :reconnect, :max_delay) || DEFAULT_MAX_DELAY
      rescue StandardError
        DEFAULT_MAX_DELAY
      end
    end
  end
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/reconnector_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/reconnector.rb spec/legion/cache/reconnector_spec.rb
git commit -m "add reconnector with exponential backoff"
```

---

### Task 16: Wire Reconnector into Cache and Local

**Files:**
- Modify: `lib/legion/cache.rb`, `lib/legion/cache/local.rb`
- Test: `spec/legion/cache/reconnector_integration_spec.rb` (new)

**Step 1: Write the failing tests**

Create `spec/legion/cache/reconnector_integration_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'reconnector integration' do
  before do
    Legion::Cache.instance_variable_set(:@client, nil)
    Legion::Cache.instance_variable_set(:@connected, false)
    Legion::Cache.instance_variable_set(:@using_local, false)
    Legion::Cache.instance_variable_set(:@using_memory, false)
    Legion::Cache.instance_variable_set(:@active_shared_driver, nil)
    Legion::Cache::Local.reset!
    Legion::Settings[:cache][:enabled] = true
  end

  it 'stats reports reconnect_attempts' do
    stats = Legion::Cache.stats
    expect(stats[:reconnect_attempts]).to be_a(Integer)
  end

  it 'setup failure triggers reconnector when enabled' do
    allow(Legion::Cache).to receive(:client).and_raise(RuntimeError, 'refused')
    allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
    allow(Legion::Cache::Local).to receive(:setup)

    Legion::Cache.setup

    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    expect(reconnector).not_to be_nil
    expect(reconnector.running?).to be(true)

    reconnector.stop
  end

  it 'does not start reconnector when disabled' do
    Legion::Settings[:cache][:enabled] = false
    allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
    allow(Legion::Cache::Local).to receive(:setup)

    Legion::Cache.setup

    reconnector = Legion::Cache.instance_variable_get(:@reconnector)
    expect(reconnector).to be_nil
    Legion::Settings[:cache][:enabled] = true
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/cache/reconnector_integration_spec.rb -v`
Expected: FAIL

**Step 3: Wire Reconnector into lifecycle**

In `lib/legion/cache.rb`:
- Add `require 'legion/cache/reconnector'`
- In `setup_shared` rescue: if `enabled?` and both shared+local fail, create and start a `Reconnector` with a `connect_block` that retries `setup_shared`.
- In `shutdown`: stop the reconnector if running.
- Wire `reconnector_attempts` into `stats`.

Same pattern in `lib/legion/cache/local.rb`.

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/cache/reconnector_integration_spec.rb -v`
Expected: PASS

**Step 5: Run full suite**

Run: `bundle exec rspec --tag ~integration -v`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/legion/cache.rb lib/legion/cache/local.rb spec/legion/cache/reconnector_integration_spec.rb
git commit -m "wire reconnector into cache lifecycle"
```

---

### Task 17: Update Helper module for new signatures

**Files:**
- Modify: `lib/legion/cache/helper.rb`
- Test: `spec/legion/cache/helper_spec.rb`

**Step 1: Read existing helper spec to understand current tests**

Read `spec/legion/cache/helper_spec.rb` and update stubs for new keyword signatures.

**Step 2: Update Helper methods**

In `lib/legion/cache/helper.rb`:
- `cache_set` calls `Legion::Cache.set(key, value, ttl: ttl, async: async, phi: phi)`
- `cache_fetch` calls `Legion::Cache.fetch(key, ttl: ttl, &block)`
- `local_cache_set` calls `Legion::Cache::Local.set(key, value, ttl: ttl, async: async, phi: phi)`
- `local_cache_fetch` calls `Legion::Cache::Local.fetch(key, ttl: ttl, &block)`
- Add `async:` parameter to `cache_set`, `cache_delete`, `cache_mset`, `local_cache_set`, `local_cache_delete`, `local_cache_mset` — defaults to `true` (inherits from the underlying methods).
- Update `FALLBACK_TTL` to `3600`.

**Step 3: Run helper specs**

Run: `bundle exec rspec spec/legion/cache/helper_spec.rb -v`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/legion/cache/helper.rb spec/legion/cache/helper_spec.rb
git commit -m "update helper module for new cache signatures"
```

---

### Task 18: Update Cacheable module for new signatures

**Files:**
- Modify: `lib/legion/cache/cacheable.rb`
- Test: `spec/legion/cacheable_spec.rb`

**Step 1: Update Cacheable**

In `lib/legion/cache/cacheable.rb`:
- `cache_write` calls `Legion::Cache.set(key, value, ttl: ttl)` (keyword TTL)
- `local_cache_write` calls `Legion::Cache::Local.set(key, value, ttl: ttl)` (keyword TTL)

**Step 2: Run cacheable specs**

Run: `bundle exec rspec spec/legion/cacheable_spec.rb -v`
Expected: PASS

**Step 3: Commit**

```bash
git add lib/legion/cache/cacheable.rb spec/legion/cacheable_spec.rb
git commit -m "update cacheable module for keyword ttl"
```

---

### Task 19: Update Settings with new async and reconnect defaults

**Files:**
- Modify: `lib/legion/cache/settings.rb`
- Test: `spec/legion/settings_spec.rb`

**Step 1: Write the failing test**

Add to `spec/legion/settings_spec.rb`:

```ruby
describe 'async settings' do
  it 'includes async defaults' do
    expect(Legion::Cache::Settings.default[:async]).to include(
      pool_size: 4,
      queue_size: 1000,
      shutdown_timeout: 5
    )
  end
end

describe 'reconnect settings' do
  it 'includes reconnect defaults' do
    expect(Legion::Cache::Settings.default[:reconnect]).to include(
      initial_delay: 1,
      max_delay: 60,
      enabled: true
    )
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/settings_spec.rb -v`
Expected: FAIL

**Step 3: Add defaults to settings**

In `lib/legion/cache/settings.rb`, add to `self.default`:
```ruby
async: {
  pool_size: 4,
  queue_size: 1000,
  shutdown_timeout: 5
}.freeze,
reconnect: {
  initial_delay: 1,
  max_delay: 60,
  enabled: true
}.freeze
```

Add same to `self.local` (can use smaller pool_size: 2 for local).

**Step 4: Run tests**

Run: `bundle exec rspec spec/legion/settings_spec.rb -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/legion/cache/settings.rb spec/legion/settings_spec.rb
git commit -m "add async and reconnect default settings"
```

---

### Task 20: Full suite validation and version bump

**Files:**
- Modify: `lib/legion/cache/version.rb`, `CHANGELOG.md`

**Step 1: Run full test suite**

Run: `bundle exec rspec -v`
Expected: All unit specs PASS (integration specs skipped unless servers are running).

**Step 2: Run rubocop**

Run: `bundle exec rubocop -A`
Then: `bundle exec rubocop`
Expected: Zero offenses.

**Step 3: Bump version**

In `lib/legion/cache/version.rb`, bump to `1.4.0` (this is a minor version bump due to new features: async writes, reconnector, stats, enabled?).

**Step 4: Update CHANGELOG.md**

```markdown
## [1.4.0] - 2026-04-06

### Added
- Async write support (`async: true` default) via concurrent-ruby ThreadPoolExecutor
- Background reconnector with exponential backoff (1s to 60s)
- `enabled?` method for both shared and local tiers (config-driven)
- `stats` method returning frozen Hash with pool, async, reconnect, and server info
- Transparent JSON serialization for Redis driver (prefix-byte based)
- `mget`/`mset` support on Local tier

### Changed
- TTL is now keyword-only (`ttl:`) across all drivers and tiers
- Default TTL: global 3600s (1 hour), local 21600s (6 hours)
- All exception handling unified: reads return nil, sync writes re-raise, lifecycle handles internally
- Redis driver catches StandardError instead of Redis::BaseError for consistency
- Removed `flush(delay)` — flush takes no arguments
- Normalized `client` kwargs across Memcached and Redis drivers
- All logging uses `log` via Legion::Logging::Helper consistently

### Fixed
- Memcached `get` nil-check bug (checked result[0] before result.nil?)
- Memcached `fetch` same nil-check bug
- Local `fetch` same nil-check/JSON-dump bug
```

**Step 5: Commit**

```bash
git add lib/legion/cache/version.rb CHANGELOG.md
git commit -m "bump version to 1.4.0, update changelog"
```

**Step 6: Final validation**

Run: `bundle exec rspec -v && bundle exec rubocop`
Expected: All green.
