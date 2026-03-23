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

  subject { helper_class.new }

  describe '#cache_namespace' do
    it 'derives from lex_filename' do
      expect(subject.cache_namespace).to eq('microsoft_teams')
    end

    it 'derives from class name when lex_filename is not defined' do
      obj = bare_class.new
      expect(obj.cache_namespace).to eq('my_extension')
    end
  end

  describe '#cache_set / #cache_get' do
    it 'delegates to Legion::Cache with namespaced key' do
      expect(Legion::Cache).to receive(:set).with('microsoft_teams:messages', 'data', 120)
      subject.cache_set(':messages', 'data', ttl: 120)
    end

    it 'delegates get to Legion::Cache with namespaced key' do
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

  describe '#local_cache_set / #local_cache_get' do
    it 'delegates to Legion::Cache::Local with namespaced key' do
      expect(Legion::Cache::Local).to receive(:set).with('microsoft_teams:hwm', 'ts', 60)
      subject.local_cache_set(':hwm', 'ts')
    end

    it 'delegates get to Legion::Cache::Local with namespaced key' do
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
end
