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

    it 'accepts the kept old handle without asking the target' do
      expect(error_for(migration('alice.example.com', old_handle: 'alice.example.com'))).to be_nil
    end

    it 'leaves the decision to createAccount when the target cannot be asked' do
      stub_request(:get, describe_server).to_return(status: 502)

      expect(error_for(migration('alice.mu.social.eurosky.social'))).to be_nil
    end
  end
end
