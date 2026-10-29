# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe Legion::Cache do
  before do
    described_class.shutdown
    @mode = ENV['LEGION_MODE']
    ENV['LEGION_MODE'] = 'lite'
    Legion::Settings[:cache][:enabled] = true
    described_class.setup
  end

  after do
    described_class.shutdown
    @mode ? ENV['LEGION_MODE'] = @mode : ENV.delete('LEGION_MODE')
  end

  it 'caches false values without recomputing them' do
    expect(described_class.fetch('key') { false }).to be(false)
    expect(described_class.fetch('key') { raise 'unexpected recomputation' }).to be(false)
  end

  it 'propagates application fetch errors without writing a value' do
    expect { described_class.fetch('key') { raise IOError, 'application failure' } }.to raise_error(IOError, 'application failure')
    expect(described_class.get('key')).to be_nil
    expect(described_class.connected?).to be(true)
  end

  it 'atomically updates the cached value through cas' do
    described_class.set_sync('counter', 4)
    expect(described_class.cas('counter') { |current| current + 3 }).to eq(7)
    expect(described_class.get('counter')).to eq(7)
  end

  it 'does not commit a failing cas block' do
    described_class.set_sync('counter', 4)
    expect { described_class.cas('counter') { raise IOError, 'application failure' } }.to raise_error(IOError, 'application failure')
    expect(described_class.get('counter')).to eq(4)
  end
end
