# frozen_string_literal: true

RSpec.describe Legion::Cache::Pool do
  it { should be_a Module }
  it { should respond_to? :connected? }
  it { should respond_to? :size }
  it { should respond_to? :available }
  it { should respond_to? :close }
  it { should respond_to? :restart }
end
