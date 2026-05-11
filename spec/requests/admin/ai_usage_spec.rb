# frozen_string_literal: true

require_relative "../../support/auth_helpers"
require "rails_helper"

RSpec.describe "GET /admin/ai_usage", type: :request do
  include AuthHelpers

  let(:admin) { create(:user, :admin) }
  let(:client_user) { create(:user) }

  describe "authorization" do
    it "returns 401 without JWT headers" do
      get "/admin/ai_usage"
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq("error" => "Unauthorized")
    end

    it "returns 403 for non-admin users" do
      signed = sign_in_user(client_user, client_type: "web")
      get "/admin/ai_usage", headers: auth_headers(signed[:access_token], signed[:refresh_token])
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)).to eq("error" => "Forbidden")
    end
  end

  describe "aggregation payload" do
    let(:day) { Date.current }
    let(:other_user) { create(:user) }

    before do
      create(:ai_session,
             user: client_user,
             started_at: day.beginning_of_day + 1.hour,
             input_tokens: 100,
             output_tokens: 50,
             model: "anthropic/claude-3.5-sonnet")
      create(:ai_session,
             user: client_user,
             started_at: day.beginning_of_day + 2.hours,
             input_tokens: 20,
             output_tokens: 30,
             model: "anthropic/claude-3.5-sonnet")
      create(:ai_session,
             user: client_user,
             started_at: day.beginning_of_day + 3.hours,
             input_tokens: 5,
             output_tokens: 5,
             model: "openai/gpt-4o-mini")

      create(:ai_session,
             user: other_user,
             started_at: day.beginning_of_day + 1.hour,
             input_tokens: 10,
             output_tokens: 10,
             model: "openai/gpt-4o-mini")
      create(:ai_session,
             user: other_user,
             started_at: day.beginning_of_day + 2.hours,
             input_tokens: 10,
             output_tokens: 10,
             model: "anthropic/claude-3.5-sonnet")
    end

    it "returns admin daily usage rows with required fields and deterministic top_model" do
      signed = sign_in_user(admin, client_type: "web")
      get "/admin/ai_usage", headers: auth_headers(signed[:access_token], signed[:refresh_token])

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to be_an(Array)

      row = body.find { |r| r["user_id"] == client_user.id && r["day"] == day.to_s }
      expect(row).not_to be_nil
      expect(row.keys).to include("user_id", "username", "day", "total_tokens", "session_count", "top_model")
      expect(row["total_tokens"]).to eq(210)
      expect(row["session_count"]).to eq(3)
      expect(row["top_model"]).to eq("anthropic/claude-3.5-sonnet")

      tie_row = body.find { |r| r["user_id"] == other_user.id && r["day"] == day.to_s }
      expect(tie_row["top_model"]).to eq("anthropic/claude-3.5-sonnet")
    end
  end
end
