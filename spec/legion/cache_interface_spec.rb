# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'

RSpec.describe 'Legion::Cache interface' do
  it 'has get method' do
    expect(Legion::Cache.method(:get)).to be_a(Method)
  end

  it 'has set method' do
    expect(Legion::Cache.method(:set)).to be_a(Method)
  end

  it 'has delete method' do
    expect(Legion::Cache.method(:delete)).to be_a(Method)
  end

  it 'has flush method' do
    expect(Legion::Cache.method(:flush)).to be_a(Method)
  end

  it 'responds to connected?' do
    expect(Legion::Cache).to respond_to(:connected?)
  end

  it 'responds to setup' do
    expect(Legion::Cache).to respond_to(:setup)
  end

  it 'responds to shutdown' do
    expect(Legion::Cache).to respond_to(:shutdown)
  end

  it 'responds to close' do
    expect(Legion::Cache).to respond_to(:close)
  end

  it 'responds to restart' do
    expect(Legion::Cache).to respond_to(:restart)
  end

  it 'responds to size' do
    expect(Legion::Cache).to respond_to(:size)
  end

  it 'responds to available' do
    expect(Legion::Cache).to respond_to(:available)
  end

  it 'has client method' do
    expect(Legion::Cache.method(:client)).to be_a(Method)
  end

  it 'responds to pool_size' do
    expect(Legion::Cache).to respond_to(:pool_size)
  end

  it 'responds to timeout' do
    expect(Legion::Cache).to respond_to(:timeout)
  end

  it 'has fetch method' do
    expect(Legion::Cache.method(:fetch)).to be_a(Method)
  end
end
