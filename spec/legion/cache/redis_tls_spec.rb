# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/redis'

RSpec.describe 'Legion::Cache::Redis TLS' do
  let(:redis_mod) { Legion::Cache::Redis.dup }

  before do
    stub_const('Legion::Crypt::TLS', Module.new)
  end

  after { redis_mod.instance_variable_set(:@client, nil) }

  describe 'TLS options passed to Redis.new' do
    before do
      allow(Legion::Cache::Settings).to receive(:resolve_servers).and_return(['127.0.0.1:6379'])
    end

    it 'passes ssl: true when TLS is enabled' do
      allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
        { enabled: true, verify: :peer, ca: '/ca.crt', cert: nil, key: nil, auto_detected: false }
      )
      expect(Redis).to receive(:new).with(hash_including(ssl: true)).and_return(double(connected?: true))
      allow(ConnectionPool).to receive(:new).and_yield

      redis_mod.client
    end

    it 'passes ssl_params with verify mode when TLS is enabled' do
      allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
        { enabled: true, verify: :peer, ca: '/ca.crt', cert: nil, key: nil, auto_detected: false }
      )
      expect(Redis).to receive(:new) do |opts|
        expect(opts[:ssl]).to be true
        expect(opts[:ssl_params][:ca_file]).to eq '/ca.crt'
      end.and_return(double(connected?: true))
      allow(ConnectionPool).to receive(:new).and_yield

      redis_mod.client
    end

    it 'skips TLS when disabled' do
      allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
        { enabled: false, verify: :peer, ca: nil, cert: nil, key: nil, auto_detected: false }
      )
      expect(Redis).to receive(:new).with(hash_not_including(ssl: true)).and_return(double(connected?: true))
      allow(ConnectionPool).to receive(:new).and_yield

      redis_mod.client
    end

    it 'skips TLS when Legion::Crypt::TLS is not defined' do
      hide_const('Legion::Crypt::TLS')
      expect(Redis).to receive(:new).with(hash_not_including(ssl: true)).and_return(double(connected?: true))
      allow(ConnectionPool).to receive(:new).and_yield

      redis_mod.client
    end
  end
end
