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
    it 'is 60' do
      expect(Legion::Cache::Helper::FALLBACK_TTL).to eq(60)
    end
  end

  describe '#cache_default_ttl' do
    it 'returns the settings value' do
      expect(subject.cache_default_ttl).to eq(60)
    end

    it 'falls back to FALLBACK_TTL when settings key is nil' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :default_ttl).and_return(nil)
      expect(subject.cache_default_ttl).to eq(60)
    end

    it 'can be overridden by a LEX' do
      obj = custom_ttl_class.new
      expect(obj.cache_default_ttl).to eq(600)
    end
  end

  describe '#local_cache_default_ttl' do
    it 'returns the local settings value' do
      expect(subject.local_cache_default_ttl).to eq(60)
    end

    it 'falls back to cache_default_ttl when local key is nil' do
      allow(Legion::Settings).to receive(:dig).with(:cache_local, :default_ttl).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:cache, :default_ttl).and_return(120)
      expect(subject.local_cache_default_ttl).to eq(120)
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
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:messages', 'data', 120, phi: false)
      subject.cache_set(':messages', 'data', ttl: 120)
    end

    it 'uses cache_default_ttl when ttl is not provided' do
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:messages', 'data', 60, phi: false)
      subject.cache_set(':messages', 'data')
    end

    it 'uses LEX override TTL when defined' do
      obj = custom_ttl_class.new
      expect(Legion::Cache).to receive(:set).with('custom_lex:key', 'val', 600, phi: false)
      obj.cache_set(':key', 'val')
    end

    it 'forwards phi: true to Legion::Cache.set' do
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:phi_data', 'secret', 7200, phi: true)
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
      expect(Legion::Cache).to receive(:delete).with('microsoft_teams:messages')
      subject.cache_delete(':messages')
    end
  end

  describe '#cache_fetch' do
    it 'delegates to Legion::Cache with namespaced key and explicit TTL' do
      expect(Legion::Cache).to receive(:fetch).with('microsoft_teams:key', 120)
      subject.cache_fetch(':key', ttl: 120)
    end

    it 'uses cache_default_ttl when ttl is not provided' do
      expect(Legion::Cache).to receive(:fetch).with('microsoft_teams:key', 60)
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
      allow(Legion::Cache).to receive(:enforce_phi_ttl).with(60, phi: false).and_return(60)
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:hwm', 'ts', 60)
      subject.local_cache_set(':hwm', 'ts')
    end

    it 'uses explicit TTL when provided' do
      allow(Legion::Cache).to receive(:enforce_phi_ttl).with(300, phi: false).and_return(300)
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:hwm', 'ts', 300)
      subject.local_cache_set(':hwm', 'ts', ttl: 300)
    end

    it 'enforces PHI TTL cap' do
      allow(Legion::Cache).to receive(:enforce_phi_ttl).with(7200, phi: true).and_return(3600)
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:phi', 'data', 3600)
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
      expect(Legion::Cache::Local).to receive(:delete).with('microsoft_teams:hwm')
      subject.local_cache_delete(':hwm')
    end
  end

  describe '#local_cache_fetch' do
    it 'uses local_cache_default_ttl when ttl is not provided' do
      expect(Legion::Cache::Local).to receive(:fetch).with('microsoft_teams:key', 60)
      subject.local_cache_fetch(':key')
    end

    it 'uses explicit TTL when provided' do
      expect(Legion::Cache::Local).to receive(:fetch).with('microsoft_teams:key', 300)
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
end
