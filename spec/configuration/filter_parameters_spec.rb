# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rails.application.config.filter_parameters" do
  let(:filters) { Rails.application.config.filter_parameters }

  it "includes the existing auth-related filters" do
    expect(filters).to include(:passw, :email, :secret, :token, :_key)
  end

  it "includes the four Phase 19 SAFETY-13 additions" do
    expect(filters).to include(:messages, :content, :tool_results, :openrouter_response)
  end

  it "filters a hash with a key containing 'content' to [FILTERED]" do
    pf = ActiveSupport::ParameterFilter.new(filters)
    out = pf.filter("content" => "secret prompt", "user_id" => 1)
    expect(out["content"]).to eq("[FILTERED]")
    expect(out["user_id"]).to eq(1)
  end

  it "filters nested hashes (e.g. messages: [{content: ...}])" do
    pf = ActiveSupport::ParameterFilter.new(filters)
    out = pf.filter("data" => { "messages" => [{ "content" => "leak", "role" => "user" }] })
    expect(out.dig("data", "messages")).to eq("[FILTERED]")
  end

  it "still passes through non-sensitive params" do
    pf = ActiveSupport::ParameterFilter.new(filters)
    out = pf.filter("device_id" => "uuid-123", "model" => "claude-sonnet-4.6")
    expect(out).to eq("device_id" => "uuid-123", "model" => "claude-sonnet-4.6")
  end
end
