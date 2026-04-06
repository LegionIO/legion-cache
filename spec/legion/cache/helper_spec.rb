# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Cache::Helper do
  let(:helper_class) do
    Class.new do
      include Legion::Cache::Helper

      def lex_filename
        'microsoft_teams'
      end
    end
  end

  let(:bare_class) do
    stub_const('Legion::Extensions::MyExtension::Runners::Foo', Class.new do
      include Legion::Cache::Helper
    end)
  end

  let(:custom_ttl_class) do
    Class.new do
      include Legion::Cache::Helper

      def lex_filename
        'custom_lex'
      end

      def cache_default_ttl
        600
      end
    end
  end

  subject { helper_class.new }

  describe 'FALLBACK_TTL' do
    it 'is 3600' do
      expect(Legion::Cache::Helper::FALLBACK_TTL).to eq(3600)
    end
  end

  describe '#cache_default_ttl' do
    it 'returns the settings value' do
      expect(subject.cache_default_ttl).to eq(3600)
    end

    it 'falls back to FALLBACK_TTL when settings key is nil' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :default_ttl).and_return(nil)
      expect(subject.cache_default_ttl).to eq(3600)
    end

    it 'can be overridden by a LEX' do
      obj = custom_ttl_class.new
      expect(obj.cache_default_ttl).to eq(600)
    end

    it 'reports exceptions and falls back when settings lookup fails' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :default_ttl).and_raise(StandardError, 'boom')
      allow(subject).to receive(:handle_exception)

      expect(subject.cache_default_ttl).to eq(3600)
      expect(subject).to have_received(:handle_exception).with(
        an_instance_of(StandardError),
        level:     :warn,
        handled:   true,
        operation: :cache_default_ttl
      )
    end
  end

  describe '#local_cache_default_ttl' do
    it 'returns the local settings value' do
      expect(subject.local_cache_default_ttl).to eq(21_600)
    end

    it 'falls back to cache_default_ttl when local key is nil' do
      allow(Legion::Settings).to receive(:dig).with(:cache_local, :default_ttl).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:cache, :default_ttl).and_return(120)
      expect(subject.local_cache_default_ttl).to eq(120)
    end

    it 'reports exceptions and falls back to cache_default_ttl when local lookup fails' do
      allow(Legion::Settings).to receive(:dig).with(:cache_local, :default_ttl).and_raise(StandardError, 'boom')
      allow(subject).to receive(:handle_exception)
      allow(subject).to receive(:cache_default_ttl).and_return(90)

      expect(subject.local_cache_default_ttl).to eq(90)
      expect(subject).to have_received(:handle_exception).with(
        an_instance_of(StandardError),
        level:     :warn,
        handled:   true,
        operation: :local_cache_default_ttl
      )
    end
  end

  describe '#cache_namespace' do
    it 'derives from lex_filename' do
      expect(subject.cache_namespace).to eq('microsoft_teams')
    end

    it 'derives from class name when lex_filename is not defined' do
      obj = bare_class.new
      expect(obj.cache_namespace).to eq('my_extension')
    end
  end

  describe '#cache_set' do
    it 'delegates to Legion::Cache with namespaced key and explicit TTL' do
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:messages', 'data', ttl: 120, async: false, phi: false)
      subject.cache_set(':messages', 'data', ttl: 120)
    end

    it 'uses cache_default_ttl when ttl is not provided' do
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:messages', 'data', ttl: 3600, async: false, phi: false)
      subject.cache_set(':messages', 'data')
    end

    it 'uses LEX override TTL when defined' do
      obj = custom_ttl_class.new
      expect(Legion::Cache).to receive(:set).with('custom_lex:key', 'val', ttl: 600, async: false, phi: false)
      obj.cache_set(':key', 'val')
    end

    it 'forwards phi: true to Legion::Cache.set' do
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:phi_data', 'secret', ttl: 7200, async: false, phi: true)
      subject.cache_set(':phi_data', 'secret', ttl: 7200, phi: true)
    end
  end

  describe '#cache_get' do
    it 'delegates to Legion::Cache with namespaced key' do
      expect(Legion::Cache).to receive(:get).with('microsoft_teams:messages').and_return('data')
      expect(subject.cache_get(':messages')).to eq('data')
    end
  end

  describe '#cache_delete' do
    it 'delegates to Legion::Cache with namespaced key' do
      expect(Legion::Cache).to receive(:delete).with('microsoft_teams:messages', async: false)
      subject.cache_delete(':messages')
    end
  end

  describe '#cache_fetch' do
    it 'delegates to Legion::Cache with namespaced key and explicit TTL' do
      expect(Legion::Cache).to receive(:fetch).with('microsoft_teams:key', ttl: 120)
      subject.cache_fetch(':key', ttl: 120)
    end

    it 'uses cache_default_ttl when ttl is not provided' do
      expect(Legion::Cache).to receive(:fetch).with('microsoft_teams:key', ttl: 3600)
      subject.cache_fetch(':key')
    end
  end

  describe '#cache_exist?' do
    it 'returns true when key has a value' do
      expect(Legion::Cache).to receive(:get).with('microsoft_teams:key').and_return('val')
      expect(subject.cache_exist?(':key')).to be true
    end

    it 'returns false when key is absent' do
      expect(Legion::Cache).to receive(:get).with('microsoft_teams:key').and_return(nil)
      expect(subject.cache_exist?(':key')).to be false
    end
  end

  describe '#local_cache_set' do
    it 'delegates to Legion::Cache::Local with namespaced key' do
      allow(Legion::Cache).to receive(:enforce_phi_ttl).with(21_600, phi: false).and_return(21_600)
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:hwm', 'ts', ttl: 21_600, async: false)
      subject.local_cache_set(':hwm', 'ts')
    end

    it 'uses explicit TTL when provided' do
      allow(Legion::Cache).to receive(:enforce_phi_ttl).with(300, phi: false).and_return(300)
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:hwm', 'ts', ttl: 300, async: false)
      subject.local_cache_set(':hwm', 'ts', ttl: 300)
    end

    it 'enforces PHI TTL cap' do
      allow(Legion::Cache).to receive(:enforce_phi_ttl).with(7200, phi: true).and_return(3600)
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:phi', 'data', ttl: 3600, async: false)
      subject.local_cache_set(':phi', 'data', ttl: 7200, phi: true)
    end
  end

  describe '#local_cache_get' do
    it 'delegates to Legion::Cache::Local with namespaced key' do
      expect(Legion::Cache::Local).to receive(:get).with('microsoft_teams:hwm').and_return('ts')
      expect(subject.local_cache_get(':hwm')).to eq('ts')
    end
  end

  describe '#local_cache_delete' do
    it 'delegates to Legion::Cache::Local with namespaced key' do
      expect(Legion::Cache::Local).to receive(:delete).with('microsoft_teams:hwm', async: false)
      subject.local_cache_delete(':hwm')
    end
  end

  describe '#local_cache_fetch' do
    it 'uses local_cache_default_ttl when ttl is not provided' do
      expect(Legion::Cache::Local).to receive(:fetch).with('microsoft_teams:key', ttl: 21_600)
      subject.local_cache_fetch(':key')
    end

    it 'uses explicit TTL when provided' do
      expect(Legion::Cache::Local).to receive(:fetch).with('microsoft_teams:key', ttl: 300)
      subject.local_cache_fetch(':key', ttl: 300)
    end
  end

  describe '#local_cache_exist?' do
    it 'returns true when key has a value' do
      expect(Legion::Cache::Local).to receive(:get).with('microsoft_teams:key').and_return('val')
      expect(subject.local_cache_exist?(':key')).to be true
    end

    it 'returns false when key is absent' do
      expect(Legion::Cache::Local).to receive(:get).with('microsoft_teams:key').and_return(nil)
      expect(subject.local_cache_exist?(':key')).to be false
    end
  end

  describe '#cache_connected?' do
    it 'delegates to Legion::Cache.connected?' do
      allow(Legion::Cache).to receive(:connected?).and_return(true)
      expect(subject.cache_connected?).to be true
    end

    it 'returns false when not connected' do
      allow(Legion::Cache).to receive(:connected?).and_return(false)
      expect(subject.cache_connected?).to be false
    end
  end

  describe '#local_cache_connected?' do
    it 'delegates to Legion::Cache::Local.connected?' do
      allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
      expect(subject.local_cache_connected?).to be true
    end
  end

  describe '#cache_pool_size' do
    it 'returns pool size when connected' do
      allow(Legion::Cache).to receive(:connected?).and_return(true)
      allow(Legion::Cache).to receive(:pool_size).and_return(10)
      expect(subject.cache_pool_size).to eq(10)
    end

    it 'returns 0 when not connected' do
      allow(Legion::Cache).to receive(:connected?).and_return(false)
      expect(subject.cache_pool_size).to eq(0)
    end
  end

  describe '#cache_pool_available' do
    it 'returns available connections when connected' do
      allow(Legion::Cache).to receive(:connected?).and_return(true)
      allow(Legion::Cache).to receive(:available).and_return(8)
      expect(subject.cache_pool_available).to eq(8)
    end

    it 'returns 0 when not connected' do
      allow(Legion::Cache).to receive(:connected?).and_return(false)
      expect(subject.cache_pool_available).to eq(0)
    end
  end

  describe '#local_cache_pool_size' do
    it 'returns pool size when connected' do
      allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
      allow(Legion::Cache::Local).to receive(:pool_size).and_return(5)
      expect(subject.local_cache_pool_size).to eq(5)
    end

    it 'returns 0 when not connected' do
      allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
      expect(subject.local_cache_pool_size).to eq(0)
    end
  end

  describe '#local_cache_pool_available' do
    it 'returns available connections when connected' do
      allow(Legion::Cache::Local).to receive(:connected?).and_return(true)
      allow(Legion::Cache::Local).to receive(:available).and_return(4)
      expect(subject.local_cache_pool_available).to eq(4)
    end

    it 'returns 0 when not connected' do
      allow(Legion::Cache::Local).to receive(:connected?).and_return(false)
      expect(subject.local_cache_pool_available).to eq(0)
    end
  end

  # --- Issue #3: cache_mget / cache_mset ---

  describe '#cache_mget' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to Legion::Cache.mget with namespaced keys and un-namespaces the result' do
        allow(Legion::Cache).to receive(:mget).with('microsoft_teams:a', 'microsoft_teams:b')
                                              .and_return({ 'microsoft_teams:a' => 'v1', 'microsoft_teams:b' => 'v2' })
        expect(subject.cache_mget(':a', ':b')).to eq({ ':a' => 'v1', ':b' => 'v2' })
      end

      it 'returns empty hash for empty key list' do
        expect(subject.cache_mget).to eq({})
      end

      it 'returns empty hash on error' do
        allow(Legion::Cache).to receive(:mget).and_raise(StandardError, 'fail')
        expect(subject.cache_mget(':x')).to eq({})
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'falls back to sequential gets and un-namespaces keys' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:a').and_return('v1')
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:b').and_return('v2')
        expect(subject.cache_mget(':a', ':b')).to eq({ ':a' => 'v1', ':b' => 'v2' })
      end

      it 'accepts an array argument' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:x').and_return('vx')
        expect(subject.cache_mget([':x'])).to eq({ ':x' => 'vx' })
      end
    end
  end

  describe '#cache_mset' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'preserves TTL semantics via sequential set calls' do
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:a', 'v1', ttl: 3600, async: false)
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:b', 'v2', ttl: 3600, async: false)
        subject.cache_mset({ ':a' => 'v1', ':b' => 'v2' })
      end

      it 'uses explicit TTL when provided' do
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:k', 'val', ttl: 300, async: false)
        subject.cache_mset({ ':k' => 'val' }, ttl: 300)
      end

      it 'returns true for empty hash without calling set' do
        expect(Legion::Cache).not_to receive(:set)
        expect(subject.cache_mset({})).to be true
      end

      it 'returns false on error' do
        allow(Legion::Cache).to receive(:set).and_raise(StandardError, 'fail')
        expect(subject.cache_mset({ ':x' => 'v' })).to be false
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'falls back to sequential sets using default TTL' do
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:a', 'v1', ttl: 3600, async: false)
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:b', 'v2', ttl: 3600, async: false)
        subject.cache_mset({ ':a' => 'v1', ':b' => 'v2' })
      end

      it 'uses explicit TTL when provided' do
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:k', 'val', ttl: 300, async: false)
        subject.cache_mset({ ':k' => 'val' }, ttl: 300)
      end

      it 'returns true on success' do
        allow(Legion::Cache).to receive(:set)
        expect(subject.cache_mset({ ':k' => 'v' })).to be true
      end
    end
  end

  describe '#local_cache_mget' do
    context 'with Redis local backend' do
      before do
        allow(subject).to receive(:local_cache_redis?).and_return(true)
        allow(Legion::Cache::Local).to receive(:get).with('microsoft_teams:a').and_return('lv1')
      end

      it 'uses sequential local gets and un-namespaces keys' do
        expect(subject.local_cache_mget(':a')).to eq({ ':a' => 'lv1' })
      end
    end

    context 'with Memcached local backend' do
      before { allow(subject).to receive(:local_cache_redis?).and_return(false) }

      it 'falls back to sequential local gets' do
        allow(Legion::Cache::Local).to receive(:get).with('microsoft_teams:a').and_return('lv1')
        expect(subject.local_cache_mget(':a')).to eq({ ':a' => 'lv1' })
      end
    end

    it 'returns empty hash for empty key list' do
      expect(subject.local_cache_mget).to eq({})
    end
  end

  describe '#local_cache_mset' do
    context 'with Redis local backend' do
      before { allow(subject).to receive(:local_cache_redis?).and_return(true) }

      it 'preserves TTL semantics via sequential local set calls' do
        expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:k', 'v', ttl: 21_600, async: false)
        subject.local_cache_mset({ ':k' => 'v' })
      end
    end

    context 'with Memcached local backend' do
      before { allow(subject).to receive(:local_cache_redis?).and_return(false) }

      it 'falls back to sequential local sets' do
        expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:k', 'v', ttl: 21_600, async: false)
        subject.local_cache_mset({ ':k' => 'v' })
      end

      it 'uses explicit TTL when provided' do
        expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:k', 'v', ttl: 120, async: false)
        subject.local_cache_mset({ ':k' => 'v' }, ttl: 120)
      end
    end

    it 'returns true for empty hash' do
      expect(subject.local_cache_mset({})).to be true
    end
  end

  # --- Issue #4: RedisHash helper methods ---

  describe '#cache_hset' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.hset with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:hset).with('microsoft_teams:h', { 'f' => 'v' }).and_return(true)
        expect(subject.cache_hset(':h', { 'f' => 'v' })).to be true
      end

      it 'returns false on error' do
        allow(Legion::Cache::RedisHash).to receive(:hset).and_raise(StandardError, 'fail')
        expect(subject.cache_hset(':h', {})).to be false
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'serializes hash as JSON via cache set (merge)' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:h').and_return(nil)
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:h', '{"f":"v"}', ttl: 3600, async: false)
        subject.cache_hset(':h', { 'f' => 'v' })
      end

      it 'merges new fields into existing JSON hash' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:h').and_return('{"existing":"val"}')
        expect(Legion::Cache).to receive(:set) do |_key, json, **_opts|
          parsed = Legion::JSON.load(json)
          expect(parsed).to include(existing: 'val', f: 'v')
        end
        subject.cache_hset(':h', { 'f' => 'v' })
      end
    end
  end

  describe '#cache_hgetall' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.hgetall with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:hgetall).with('microsoft_teams:h').and_return({ 'f' => 'v' })
        expect(subject.cache_hgetall(':h')).to eq({ 'f' => 'v' })
      end

      it 'returns nil on error' do
        allow(Legion::Cache::RedisHash).to receive(:hgetall).and_raise(StandardError, 'fail')
        expect(subject.cache_hgetall(':h')).to be_nil
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'deserializes JSON from cache and returns string-key hash' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:h').and_return('{"f":"v"}')
        result = subject.cache_hgetall(':h')
        expect(result).to eq({ 'f' => 'v' })
      end

      it 'returns nil when key is absent' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:h').and_return(nil)
        expect(subject.cache_hgetall(':h')).to be_nil
      end
    end
  end

  describe '#cache_hdel' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.hdel with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:hdel).with('microsoft_teams:h', 'f1').and_return(1)
        expect(subject.cache_hdel(':h', 'f1')).to eq(1)
      end

      it 'returns 0 on error' do
        allow(Legion::Cache::RedisHash).to receive(:hdel).and_raise(StandardError, 'fail')
        expect(subject.cache_hdel(':h', 'f')).to eq(0)
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'removes specified fields from JSON hash and returns count' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:h').and_return('{"a":"1","b":"2"}')
        expect(Legion::Cache).to receive(:set).with('microsoft_teams:h', anything, ttl: 3600, async: false) do |_k, json, **_opts|
          parsed = Legion::JSON.load(json)
          expect(parsed.keys.map(&:to_s)).not_to include('a')
        end
        expect(subject.cache_hdel(':h', 'a')).to eq(1)
      end

      it 'returns 0 when key is absent' do
        allow(Legion::Cache).to receive(:get).with('microsoft_teams:h').and_return(nil)
        expect(subject.cache_hdel(':h', 'f')).to eq(0)
      end
    end
  end

  describe '#cache_zadd' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.zadd with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:zadd).with('microsoft_teams:z', 1.5, 'member').and_return(true)
        expect(subject.cache_zadd(':z', 1.5, 'member')).to be true
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'raises NotImplementedError' do
        expect { subject.cache_zadd(':z', 1.0, 'm') }.to raise_error(NotImplementedError, /cache_zadd/)
      end
    end
  end

  describe '#cache_zrangebyscore' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.zrangebyscore with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:zrangebyscore)
          .with('microsoft_teams:z', 0, 100, limit: nil)
          .and_return(%w[a b])
        expect(subject.cache_zrangebyscore(':z', 0, 100)).to eq(%w[a b])
      end

      it 'passes limit option' do
        expect(Legion::Cache::RedisHash).to receive(:zrangebyscore)
          .with('microsoft_teams:z', 0, 100, limit: [0, 5])
          .and_return(['a'])
        expect(subject.cache_zrangebyscore(':z', 0, 100, limit: [0, 5])).to eq(['a'])
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'raises NotImplementedError' do
        expect { subject.cache_zrangebyscore(':z', 0, 100) }.to raise_error(NotImplementedError, /cache_zrangebyscore/)
      end
    end
  end

  describe '#cache_zrem' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.zrem with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:zrem).with('microsoft_teams:z', 'm').and_return(true)
        expect(subject.cache_zrem(':z', 'm')).to be true
      end
    end

    context 'with Memcached backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'raises NotImplementedError' do
        expect { subject.cache_zrem(':z', 'm') }.to raise_error(NotImplementedError, /cache_zrem/)
      end
    end
  end

  describe '#cache_expire' do
    context 'with Redis backend' do
      before { allow(subject).to receive(:cache_redis?).and_return(true) }

      it 'delegates to RedisHash.expire with namespaced key' do
        expect(Legion::Cache::RedisHash).to receive(:expire).with('microsoft_teams:k', 300).and_return(true)
        expect(subject.cache_expire(':k', 300)).to be true
      end

      it 'returns false on error' do
        allow(Legion::Cache::RedisHash).to receive(:expire).and_raise(StandardError, 'fail')
        expect(subject.cache_expire(':k', 60)).to be false
      end
    end

    context 'with Memcached backend (no-op)' do
      before { allow(subject).to receive(:cache_redis?).and_return(false) }

      it 'returns false without calling RedisHash' do
        expect(Legion::Cache::RedisHash).not_to receive(:expire)
        expect(subject.cache_expire(':k', 300)).to be false
      end
    end
  end
end
