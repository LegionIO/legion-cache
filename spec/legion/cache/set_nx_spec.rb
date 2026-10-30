# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'
require 'legion/cache/memcached'
require 'legion/cache/memory'

RSpec.describe 'Legion::Cache set_nx' do
  describe Legion::Cache::Memory do
    before { described_class.reset! }

    describe '.set_nx' do
      it 'returns true and stores value when key does not exist' do
        result = described_class.set_nx('nx-key', 'value', ttl: 60)
        expect(result).to be true
        expect(described_class.get('nx-key')).to eq('value')
      end

      it 'returns false and does not overwrite when key already exists' do
        described_class.set('nx-key', 'original', ttl: 60)
        result = described_class.set_nx('nx-key', 'overwrite', ttl: 60)
        expect(result).to be false
        expect(described_class.get('nx-key')).to eq('original')
      end

      it 'returns true after an expired key has been purged' do
        described_class.set('nx-expire', 'old', ttl: 0.05)
        sleep 0.07
        result = described_class.set_nx('nx-expire', 'new', ttl: 60)
        expect(result).to be true
        expect(described_class.get('nx-expire')).to eq('new')
      end

      it 'is atomic under concurrent access' do
        winners = []
        mutex = Mutex.new
        threads = 10.times.map do |i|
          Thread.new do
            won = described_class.set_nx('race-key', "value-#{i}", ttl: 60)
            mutex.synchronize { winners << i } if won
          end
        end
        threads.each(&:join)
        expect(winners.size).to eq(1)
      end
    end
  end
end
