# frozen_string_literal: true

require 'rails_helper'

# sebastian.eurosky.social "migrating" to eurosky.social to get a .mu.social
# handle is not a migration: the pipeline would treat it as a return to an
# existing account and end by deactivating that same account.
RSpec.describe MigrationsController, type: :controller do
  def stub_describe_server(host, did:, domains: [])
    stub_request(:get, "#{host}/xrpc/com.atproto.server.describeServer")
      .to_return(status: 200, body: { did: did, availableUserDomains: domains }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  describe 'POST #check_pds' do
    it 'refuses the server the account already lives on' do
      post :check_pds, params: { pds_host: 'https://eurosky.social', source_pds_host: 'https://eurosky.social' }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('already lives on (https://eurosky.social)')
    end

    it 'refuses the same server under another name' do
      stub_describe_server('https://blacksky.app', did: 'did:web:blacksky.app')
      stub_describe_server('https://myatproto.social', did: 'did:web:blacksky.app')

      post :check_pds, params: { pds_host: 'https://myatproto.social', source_pds_host: 'https://blacksky.app' }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'checks a different server as before' do
      stub_describe_server('https://blacksky.app', did: 'did:web:blacksky.app')
      stub_describe_server('https://eurosky.social', did: 'did:web:eurosky.social', domains: ['.eurosky.social', '.mu.social'])

      post :check_pds, params: { pds_host: 'https://eurosky.social', source_pds_host: 'https://blacksky.app' }, format: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['available_user_domains']).to eq(['.eurosky.social', '.mu.social'])
    end
  end

  describe 'POST #create' do
    before do
      allow(GoatService).to receive(:resolve_handle).with('sebastian.eurosky.social')
        .and_return({ did: 'did:plc:samepds123', pds_host: 'https://eurosky.social' })
    end

    it 'refuses a move onto the server the account already lives on' do
      expect {
        post :create, params: { migration: {
          email: 'test@example.com', old_handle: 'sebastian.eurosky.social', new_handle: 'sebastian.mu.social',
          new_pds_host: 'https://eurosky.social', old_access_token: 'a', old_refresh_token: 'r',
          new_access_token: 'na', new_refresh_token: 'nr', legal_consent: '1'
        } }
      }.not_to change(Migration, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(assigns(:migration).errors[:base].join).to include('already lives on')
    end
  end
end
