# frozen_string_literal: true

require 'spec_helper'
require 'concurrent-ruby'
require 'legion/cache/reconnector'

RSpec.describe Legion::Cache::Reconnector do
  let(:connect_called) { Concurrent::AtomicFixnum.new(0) }
  let(:connect_block) do
    lambda {
      connect_called.increment
      raise 'nope'
    }
  end
  let(:enabled_block) { -> { true } }

  subject(:reconnector) do
    described_class.new(
      tier:          :shared,
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
      reconnector.stop
      expect(connect_called.value).to eq(0)
    end
  end
end
