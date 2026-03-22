# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache/memcached'

RSpec.describe 'Legion::Cache::Memcached TLS' do
  let(:mc_mod) { Legion::Cache::Memcached.dup }

  before do
    stub_const('Legion::Crypt::TLS', Module.new)
    allow(Legion::Cache::Settings).to receive(:resolve_servers).and_return(['127.0.0.1:11211'])
    allow(Dalli).to receive(:logger=)
  end

  after { mc_mod.instance_variable_set(:@client, nil) }

  describe 'TLS options passed to Dalli::Client' do
    it 'passes ssl_context when TLS is enabled' do
      allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
        { enabled: true, verify: :peer, ca: '/ca.crt', cert: nil, key: nil, auto_detected: false }
      )
      expect(Dalli::Client).to receive(:new) do |_servers, opts|
        expect(opts[:ssl_context]).to be_a(OpenSSL::SSL::SSLContext)
      end.and_return(double(alive!: true))
      allow(ConnectionPool).to receive(:new).and_yield

      mc_mod.client
    end

    it 'skips ssl_context when TLS is disabled' do
      allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
        { enabled: false, verify: :peer, ca: nil, cert: nil, key: nil, auto_detected: false }
      )
      expect(Dalli::Client).to receive(:new) do |_servers, opts|
        expect(opts).not_to have_key(:ssl_context)
      end.and_return(double(alive!: true))
      allow(ConnectionPool).to receive(:new).and_yield

      mc_mod.client
    end

    it 'skips ssl_context when Legion::Crypt::TLS is not defined' do
      hide_const('Legion::Crypt::TLS')
      expect(Dalli::Client).to receive(:new) do |_servers, opts|
        expect(opts).not_to have_key(:ssl_context)
      end.and_return(double(alive!: true))
      allow(ConnectionPool).to receive(:new).and_yield

      mc_mod.client
    end
  end
end
