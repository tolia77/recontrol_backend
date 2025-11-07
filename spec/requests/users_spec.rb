require 'rails_helper'

RSpec.describe "Users API", type: :request do
  let(:admin) { create(:user, role: :admin) }
  let(:user) { create(:user) }
  let(:headers) { { 'Authorization' => "Bearer #{access_token}" } }

  # Helper to create session and token manually using model (bypassing auth flow)
  def issue_token_for(u)
    session = Session.create!(user: u, client_type: 'web')
    payload = { sub: u.id, jti: session.jti, session_key: session.session_key, exp: 30.minutes.from_now.to_i }
    JWTUtils.encode_access(payload)
  end

  describe 'GET /users' do
    context 'as admin' do
      let(:access_token) { issue_token_for(admin) }
      it 'returns all users' do
        user # create regular user
        get '/users', headers: headers
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json.length).to be >= 2
      end
    end

    context 'as regular user' do
      let(:access_token) { issue_token_for(user) }
      it 'is forbidden' do
        get '/users', headers: headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe 'GET /users/:id' do
    context 'self access' do
      let(:access_token) { issue_token_for(user) }
      it 'returns own data' do
        get "/users/#{user.id}", headers: headers
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['id']).to eq(user.id)
      end
    end

    context 'other user access' do
      let(:access_token) { issue_token_for(user) }
      it 'is forbidden' do
        get "/users/#{admin.id}", headers: headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'admin access other user' do
      let(:access_token) { issue_token_for(admin) }
      it 'returns data' do
        get "/users/#{user.id}", headers: headers
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'PATCH /users/:id' do
    context 'user updating self' do
      let(:access_token) { issue_token_for(user) }
      it 'updates allowed fields' do
        patch "/users/#{user.id}", params: { user: { username: 'newname' } }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(user.reload.username).to eq('newname')
      end
    end

    context 'user updating role (not allowed)' do
      let(:access_token) { issue_token_for(user) }
      it 'ignores role change' do
        patch "/users/#{user.id}", params: { user: { role: 'admin' } }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(user.reload.role).not_to eq('admin')
      end
    end

    context 'admin updating other user role' do
      let(:access_token) { issue_token_for(admin) }
      it 'changes role' do
        patch "/users/#{user.id}", params: { user: { role: 'admin' } }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(user.reload.role).to eq('admin')
      end
    end
  end

  describe 'DELETE /users/:id' do
    context 'admin deletes user' do
      let(:access_token) { issue_token_for(admin) }
      it 'deletes' do
        delete "/users/#{user.id}", headers: headers
        expect(response).to have_http_status(:no_content)
        expect(User.find_by(id: user.id)).to be_nil
      end
    end

    context 'regular user delete self (not allowed)' do
      let(:access_token) { issue_token_for(user) }
      it 'forbidden' do
        delete "/users/#{user.id}", headers: headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end

