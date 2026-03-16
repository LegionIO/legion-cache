# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/local'

RSpec.describe Legion::Cache::Local do
  describe 'module interface' do
    it 'responds to setup' do
      expect(described_class).to respond_to(:setup)
    end

    it 'responds to shutdown' do
      expect(described_class).to respond_to(:shutdown)
    end

    it 'responds to connected?' do
      expect(described_class).to respond_to(:connected?)
    end

    it 'responds to get' do
      expect(described_class).to respond_to(:get)
    end

    it 'responds to set' do
      expect(described_class).to respond_to(:set)
    end

    it 'responds to delete' do
      expect(described_class).to respond_to(:delete)
    end

    it 'responds to flush' do
      expect(described_class).to respond_to(:flush)
    end

    it 'responds to fetch' do
      expect(described_class).to respond_to(:fetch)
    end

    it 'responds to client' do
      expect(described_class).to respond_to(:client)
    end

    it 'responds to reset!' do
      expect(described_class).to respond_to(:reset!)
    end

    it 'responds to close' do
      expect(described_class).to respond_to(:close)
    end

    it 'responds to restart' do
      expect(described_class).to respond_to(:restart)
    end

    it 'responds to size' do
      expect(described_class).to respond_to(:size)
    end

    it 'responds to available' do
      expect(described_class).to respond_to(:available)
    end

    it 'responds to pool_size' do
      expect(described_class).to respond_to(:pool_size)
    end

    it 'responds to timeout' do
      expect(described_class).to respond_to(:timeout)
    end
  end

  describe 'not connected' do
    before { described_class.reset! }

    it 'reports not connected' do
      expect(described_class.connected?).to eq false
    end
  end
end
