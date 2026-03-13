# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/version'

RSpec.describe 'Legion::Cache::VERSION' do
  it 'exists' do
    expect(Legion::Cache::VERSION).not_to be_nil
  end

  it 'is a string' do
    expect(Legion::Cache::VERSION).to be_a(String)
  end

  it 'follows semantic versioning format' do
    expect(Legion::Cache::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end
end
