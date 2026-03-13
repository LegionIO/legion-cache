# legion-cache

Caching wrapper for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides a consistent interface for Memcached (via `dalli`) and Redis (via `redis` gem) with connection pooling. Driver selection is config-driven.

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
Legion::Cache.set('foobar', 'testing', ttl: 10)
Legion::Cache.get('foobar') # => 'testing'
```

## Configuration

```json
{
  "driver": "dalli",
  "servers": ["127.0.0.1:11211"],
  "connected": false,
  "enabled": true,
  "namespace": "legion",
  "compress": false,
  "cache_nils": false,
  "pool_size": 10,
  "timeout": 10,
  "expires_in": 0
}
```

Set `"driver": "redis"` and update `servers` to use Redis instead of Memcached.

## Requirements

- Ruby >= 3.4
- Memcached or Redis server

## License

Apache-2.0
