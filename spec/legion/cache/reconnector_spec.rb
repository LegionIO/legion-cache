# frozen_string_literal: true

require 'spec_helper'
require 'concurrent-ruby'
require 'legion/cache/reconnector'

RSpec.describe Legion::Cache::Reconnector do
  let(:connect_called) { Concurrent::AtomicFixnum.new(0) }
  let(:connect_block) { -> { connect_called.increment } }
  let(:enabled_block) { -> { true } }
  let(:initial_delay) { 60 }

  subject(:reconnector) do
    described_class.new(tier: :shared, connect_block: connect_block, enabled_block: enabled_block)
  end

  before do
    allow(Legion::Settings).to receive(:dig).and_call_original
    allow(Legion::Settings).to receive(:dig).with(:cache, :enabled).and_return(true)
    allow(Legion::Settings).to receive(:dig).with(:cache, :reconnect, :enabled).and_return(true)
    allow(Legion::Settings).to receive(:dig).with(:cache, :reconnect, :initial_delay).and_return(initial_delay)
    allow(Legion::Settings).to receive(:dig).with(:cache, :reconnect, :max_delay).and_return(60)
    stub_const('Legion::Cache::Reconnector::STOP_TIMEOUT', 0.1)
  end

  after { reconnector.stop }

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until yield
      raise 'reconnector did not reach the expected state' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end

  describe '#stop' do
    it 'interrupts a long backoff without running a connection callback' do
      reconnector.start
      wait_until { reconnector.next_retry_at }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reconnector.stop

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      expect(reconnector.running?).to be(false)
      expect(reconnector.next_retry_at).to be_nil
      expect(connect_called.value).to eq(0)
    end

    context 'with a stuck connection callback' do
      let(:initial_delay) { 0 }
      let(:entered) { Queue.new }
      let(:release) { Queue.new }
      let(:finished) { Queue.new }
      let(:connect_block) do
        lambda {
          entered << Thread.current
          begin
            release.pop
            connect_called.increment
          ensure
            finished << true
          end
        }
      end

      it 'cancels and joins the callback before returning, and can restart' do
        reconnector.start
        worker = entered.pop(timeout: 2)
        expect(worker).to be_a(Thread)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reconnector.stop

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
        expect(worker.alive?).to be(false)
        expect(finished.pop(timeout: 2)).to be(true)
        expect(reconnector.running?).to be(false)
        expect(connect_called.value).to eq(0)

        release << true
        reconnector.start
        restarted_worker = entered.pop(timeout: 2)
        expect(restarted_worker).not_to equal(worker)
        expect(restarted_worker.join(2)).to equal(restarted_worker)
        expect(connect_called.value).to eq(1)
      end

      it 'does not hide a live worker while stop is waiting for it' do
        reconnector.start
        worker = entered.pop(timeout: 2)
        stopper = Thread.new { reconnector.stop }
        wait_until { stopper.status == 'sleep' }

        expect(reconnector.running?).to be(true)
        reconnector.start
        release << true
        expect(stopper.join(2)).to equal(stopper)
        expect(worker.alive?).to be(false)
        expect(entered).to be_empty
        expect(connect_called.value).to eq(1)
      ensure
        stopper&.join(2)
      end
    end

    context 'when called inside the connection callback' do
      let(:initial_delay) { 0 }
      let(:entered) { Queue.new }
      let(:connect_block) do
        lambda {
          entered << Thread.current
          reconnector.stop
          connect_called.increment
        }
      end

      it 'terminates without self-joining or continuing the callback' do
        reconnector.start
        worker = entered.pop(timeout: 2)
        expect(worker.join(2)).to equal(worker)
        expect(reconnector.running?).to be(false)
        expect(connect_called.value).to eq(0)

        reconnector.start
        restarted_worker = entered.pop(timeout: 2)
        expect(restarted_worker).not_to equal(worker)
        expect(restarted_worker.join(2)).to equal(restarted_worker)
      end
    end
  end

  describe 'retrying failed connections' do
    let(:initial_delay) { 0.01 }
    let(:entered) { Queue.new }
    let(:release) { Queue.new }
    let(:connect_block) do
      lambda {
        attempt = connect_called.increment
        entered << [Thread.current, reconnector.attempts, reconnector.next_retry_at]
        release.pop
        raise 'connection refused' if attempt < 3
      }
    end

    it 'backs off after failures and resets its attempt count after success' do
      reconnector.start
      first = entered.pop(timeout: 2)
      release << true
      second = entered.pop(timeout: 2)
      release << true
      third = entered.pop(timeout: 2)

      expect([first[1], second[1], third[1]]).to eq([0, 1, 2])
      expect(second[2] - first[2]).to be >= 0.02
      expect(third[2] - second[2]).to be >= 0.04
      release << true
      expect(third[0].join(2)).to equal(third[0])
      expect(reconnector.attempts).to eq(0)
      expect(reconnector.next_retry_at).to be_nil
      expect(connect_called.value).to eq(3)
    end
  end

  describe 'reconnect configuration' do
    let(:initial_delay) { 0 }
    let(:entered) { Queue.new }
    let(:connect_block) do
      lambda {
        connect_called.increment
        entered << Thread.current
      }
    end

    it 'does not start when cache.reconnect.enabled is false, and can start after enabling it' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :reconnect, :enabled).and_return(false)
      reconnector.start
      expect(reconnector.running?).to be(false)
      expect(connect_called.value).to eq(0)

      allow(Legion::Settings).to receive(:dig).with(:cache, :reconnect, :enabled).and_return(true)
      reconnector.start
      worker = entered.pop(timeout: 2)
      expect(worker.join(2)).to equal(worker)
      expect(connect_called.value).to eq(1)
    end

    it 'does not start when cache.enabled is false even if the enabled callback permits it' do
      allow(Legion::Settings).to receive(:dig).with(:cache, :enabled).and_return(false)
      reconnector.start
      expect(reconnector.running?).to be(false)
      expect(connect_called.value).to eq(0)
    end

    context 'when reconnect is disabled during backoff' do
      let(:initial_delay) { 0.05 }

      it 'rechecks the policy before calling the connection callback' do
        enabled = Concurrent::AtomicBoolean.new(true)
        checked_disabled = Queue.new
        allow(Legion::Settings).to receive(:dig).with(:cache, :reconnect, :enabled) do
          value = enabled.true?
          checked_disabled << true unless value
          value
        end
        reconnector.start
        wait_until { reconnector.next_retry_at }
        enabled.make_false
        expect(checked_disabled.pop(timeout: 2)).to be(true)
        reconnector.stop
        expect(connect_called.value).to eq(0)
      end
    end
  end

  describe 'cache availability' do
    let(:initial_delay) { 0 }
    let(:checked) { Queue.new }
    let(:enabled_block) do
      lambda {
        checked << true
        false
      }
    end

    it 'does not connect when the cache is disabled' do
      reconnector.start
      expect(checked.pop(timeout: 2)).to be(true)
      reconnector.stop
      expect(connect_called.value).to eq(0)
    end
  end
end
