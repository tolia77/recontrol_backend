require 'rails_helper'

RSpec.describe "Auths", type: :request do
  describe "GET /login" do
    it "returns http success" do
      get "/auth/login"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /register" do
    it "returns http success" do
      get "/auth/register"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /logout" do
    it "returns http success" do
      get "/auth/logout"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /refresh" do
    it "returns http success" do
      get "/auth/refresh"
      expect(response).to have_http_status(:success)
    end
  end

end
