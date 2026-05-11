# frozen_string_literal: true

module Admin
  class AiUsageController < ApplicationController
    before_action :authenticate_user!
    before_action :authorize_admin!

    def index
      totals = AiSession.joins(:user)
        .group("ai_sessions.user_id", "users.username", "DATE(ai_sessions.started_at)")
        .select(
          "ai_sessions.user_id AS user_id",
          "users.username AS username",
          "DATE(ai_sessions.started_at) AS day",
          "SUM(COALESCE(ai_sessions.input_tokens, 0) + COALESCE(ai_sessions.output_tokens, 0)) AS total_tokens",
          "COUNT(*) AS session_count"
        )

      top_models = AiSession
        .from(
          AiSession
            .select(
              "ai_sessions.user_id AS user_id",
              "DATE(ai_sessions.started_at) AS day",
              "ai_sessions.model AS model",
              "COUNT(*) AS model_count"
            )
            .group("ai_sessions.user_id", "DATE(ai_sessions.started_at)", "ai_sessions.model"),
          :ranked_models
        )
        .select("DISTINCT ON (user_id, day) user_id, day, model AS top_model")
        .order(Arel.sql("user_id, day, model_count DESC, model ASC"))

      top_model_index = top_models.each_with_object({}) do |row, acc|
        acc[[row.user_id, row.day.to_s]] = row.top_model
      end

      payload = totals.map do |row|
        key = [row.user_id, row.day.to_s]
        {
          user_id: row.user_id,
          username: row.username,
          day: row.day.to_s,
          total_tokens: row.total_tokens.to_i,
          session_count: row.session_count.to_i,
          top_model: top_model_index[key]
        }
      end

      render json: payload
    end

    private

    def authorize_admin!
      render json: { error: "Forbidden" }, status: :forbidden unless current_user&.admin?
    end
  end
end
