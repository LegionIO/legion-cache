# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/settings'

RSpec.describe Legion::Cache::Settings do
  subject(:default) { Legion::Cache::Settings.default }
  it { should respond_to :default }
  context 'default attributes' do
    before { default.default }
    it { should be_a Hash }
    it { should include(enabled: true) }
    it { should include(servers: ['127.0.0.1:11211']) }
    it { should include(connected: false) }
    it { should include(namespace: 'legion') }
  end

  context 'should have a driver' do
    subject(:driver) { Legion::Cache::Settings.driver }
    it { should be_a String }
  end

  context 'should be able to override driver' do
    subject(:driver) { Legion::Cache::Settings.driver('redis') }
    it { should be_a String }
    it { should eq 'redis' }
  end

  context 'should be able to override driver' do
    subject(:driver) { Legion::Cache::Settings.driver('dalli') }
    it { should be_a String }
    it { should eq 'dalli' }
  end

  context 'should be able to default to dalli' do
    subject(:driver) { Legion::Cache::Settings.driver('foobar') }
    it { should be_a String }
    it { should eq 'dalli' }
  end
end
