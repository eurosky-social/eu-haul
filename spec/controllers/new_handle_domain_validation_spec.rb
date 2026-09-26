# frozen_string_literal: true

require 'rails_helper'

# A new account's handle must be one name on one of the target's handle
# domains. Before this check, a stale domain list or a dotted name
# (alice.mu.social.eurosky.social) passed the wizard and only failed at
# createAccount, after the user had already verified their email.
RSpec.describe MigrationsController, type: :controller do
  describe '#new_handle_domain_error' do
    def migration(new_handle, old_handle: 'alice.bsky.social', new_pds_host: 'https://eurosky.social')
      Migration.new(old_handle: old_handle, new_handle: new_handle, new_pds_host: new_pds_host)
    end

    def error_for(migration)
      controller.send(:new_handle_domain_error, migration)
    end

    def describe_server(host = 'https://eurosky.social')
      "#{host}/xrpc/com.atproto.server.describeServer"
    end

    def stub_domains(domains, host: 'https://eurosky.social')
      stub_request(:get, describe_server(host))
        .to_return(status: 200, body: { availableUserDomains: domains }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    it 'accepts a name on any of the target domains, not just the first' do
      stub_domains(['.eurosky.social', '.mu.social'])

      expect(error_for(migration('alice.eurosky.social'))).to be_nil
      expect(error_for(migration('alice.mu.social'))).to be_nil
    end

    it 'accepts a target given without scheme' do
      stub_domains(['.eurosky.social', '.mu.social'])

      expect(error_for(migration('alice.mu.social', new_pds_host: 'eurosky.social'))).to be_nil
    end

    it 'rejects a dotted name on a target domain' do
      stub_domains(['.eurosky.social', '.mu.social'])

      error = error_for(migration('alice.mu.social.eurosky.social'))
      expect(error).to include('alice.mu.social.eurosky.social')
      expect(error).to include('.eurosky.social, .mu.social')
    end

    it 'rejects a handle on a domain the target does not hand out' do
      stub_domains(['.oso.social'], host: 'https://pds.oso.social')

      expect(error_for(migration('alice.pds.oso.social', new_pds_host: 'https://pds.oso.social'))).to be_present
    end

    it 'accepts a kept custom-domain handle without asking the target' do
      allow(GoatService).to receive(:handle_matches_source_pds?).with('alice.example.com', when_unknown: false).and_return(false)

      expect(error_for(migration('alice.example.com', old_handle: 'alice.example.com'))).to be_nil
    end

    it 'refuses keeping a handle the old server owns' do
      allow(GoatService).to receive(:handle_matches_source_pds?)
        .with('iustitia100.latinsky.app', when_unknown: false).and_return(true)

      error = error_for(migration('iustitia100.latinsky.app', old_handle: 'iustitia100.latinsky.app'))
      expect(error).to include('iustitia100.latinsky.app belongs to your current server')
    end

    it 'refuses keeping a handle on a built-in server domain without asking anyone' do
      expect(GoatService).not_to receive(:handle_matches_source_pds?)

      expect(error_for(migration('alice.bsky.social', old_handle: 'alice.bsky.social'))).to be_present
    end

    it 'leaves the decision to createAccount when the target cannot be asked' do
      stub_request(:get, describe_server).to_return(status: 502)

      expect(error_for(migration('alice.mu.social.eurosky.social'))).to be_nil
    end
  end
end
