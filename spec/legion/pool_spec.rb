# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/pool'

RSpec.describe Legion::Cache::Pool do
  it 'is a Module' do
    expect(described_class).to be_a(Module)
  end

  context 'when included in a test class' do
    let(:test_class) do
      Class.new do
        include Legion::Cache::Pool
      end
    end
    let(:instance) { test_class.new }

    it '#connected? returns false initially' do
      expect(instance.connected?).to eq(false)
    end

    it '#timeout returns an integer' do
      expect(instance.timeout).to be_a(Integer)
    end

    it '#pool_size returns an integer' do
      expect(instance.pool_size).to be_a(Integer)
    end
  end

  it 'defines expected instance methods' do
    expect(described_class.instance_methods).to include(:connected?, :size, :timeout, :pool_size, :available, :close, :restart)
  end
end
