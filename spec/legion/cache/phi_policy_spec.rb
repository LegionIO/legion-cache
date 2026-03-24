# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'Legion::Cache PHI TTL policy' do
  before do
    allow(Legion::Settings).to receive(:dig).with(:cache, :compliance, :phi_max_ttl).and_return(3600)
  end

  describe 'Legion::Cache.phi_max_ttl' do
    it 'returns the configured phi_max_ttl' do
      expect(Legion::Cache.phi_max_ttl).to eq(3600)
    end
  end

  describe 'Legion::Cache.enforce_phi_ttl' do
    it 'caps ttl at phi_max_ttl when phi: true' do
      result = Legion::Cache.enforce_phi_ttl(7200, phi: true)
      expect(result).to eq(3600)
    end

    it 'returns original ttl when phi is false' do
      result = Legion::Cache.enforce_phi_ttl(7200, phi: false)
      expect(result).to eq(7200)
    end

    it 'returns original ttl when phi key is absent' do
      result = Legion::Cache.enforce_phi_ttl(7200)
      expect(result).to eq(7200)
    end

    it 'caps even if ttl is below phi_max_ttl -- passes through lower value' do
      result = Legion::Cache.enforce_phi_ttl(60, phi: true)
      expect(result).to eq(60)
    end

    it 'caps at phi_max_ttl when ttl exceeds it and phi: true' do
      result = Legion::Cache.enforce_phi_ttl(86_400, phi: true)
      expect(result).to eq(3600)
    end
  end

  describe 'Legion::Cache.set with phi: true option' do
    before do
      allow(Legion::Cache::Memory).to receive(:set)
      Legion::Cache.instance_variable_set(:@using_memory, true)
    end

    after do
      Legion::Cache.instance_variable_set(:@using_memory, false)
    end

    it 'enforces phi max ttl before delegating to memory adapter' do
      Legion::Cache.set('phi:task:99', 'value', 7200, phi: true)
      expect(Legion::Cache::Memory).to have_received(:set).with('phi:task:99', 'value', 3600)
    end

    it 'passes original ttl when phi is not set' do
      Legion::Cache.set('task:99', 'value', 7200)
      expect(Legion::Cache::Memory).to have_received(:set).with('task:99', 'value', 7200)
    end
  end
end
