# frozen_string_literal: true

class AiUsage < ApplicationRecord
  belongs_to :user

  ROLE_LIMITS = {
    "client" => 100_000,
    "admin"  => 100_000
  }.freeze

  class QuotaExceededError < StandardError
    attr_reader :user_id, :tokens_used, :limit

    def initialize(user_id:, tokens_used:, limit:)
      @user_id = user_id
      @tokens_used = tokens_used
      @limit = limit
      super("quota exceeded: user=#{user_id} used=#{tokens_used}/#{limit}")
    end
  end

  def self.charge!(user, input_tokens:, output_tokens:)
    limit  = ROLE_LIMITS.fetch(user.role.to_s)
    delta  = input_tokens.to_i + output_tokens.to_i
    today  = Date.current

    if delta > limit
      raise QuotaExceededError.new(user_id: user.id, tokens_used: delta, limit: limit)
    end

    sql = <<~SQL.squish
      WITH attempted AS (
        INSERT INTO ai_usages (user_id, usage_date, tokens_used, created_at, updated_at)
        VALUES ($1, $2, $3, NOW(), NOW())
        ON CONFLICT (user_id, usage_date)
        DO UPDATE SET
          tokens_used = ai_usages.tokens_used + EXCLUDED.tokens_used,
          updated_at  = NOW()
        WHERE ai_usages.tokens_used + EXCLUDED.tokens_used <= $4
        RETURNING tokens_used, TRUE AS applied
      ),
      existing AS (
        SELECT tokens_used
        FROM ai_usages
        WHERE user_id = $1 AND usage_date = $2
      )
      SELECT
        COALESCE(
          (SELECT tokens_used FROM attempted),
          (SELECT tokens_used + $3 FROM existing),
          $3
        ) AS tokens_used,
        COALESCE((SELECT applied FROM attempted), FALSE) AS applied
    SQL

    result = connection.exec_query(sql, "AiUsage Charge", [user.id, today, delta, limit])
    new_total, applied = result.rows.first
    new_total = new_total.to_i
    applied = ActiveModel::Type::Boolean.new.cast(applied)

    unless applied
      raise QuotaExceededError.new(user_id: user.id, tokens_used: new_total, limit: limit)
    end

    new_total
  end

  def self.current_total(user)
    today  = Date.current

    sql = <<~SQL.squish
      INSERT INTO ai_usages (user_id, usage_date, tokens_used, created_at, updated_at)
      VALUES ($1, $2, 0, NOW(), NOW())
      ON CONFLICT (user_id, usage_date)
      DO UPDATE SET
        tokens_used = ai_usages.tokens_used + 0,
        updated_at = NOW()
      RETURNING tokens_used
    SQL

    result = connection.exec_query(sql, "AiUsage Read", [user.id, today])
    result.rows.first&.first.to_i
  end

  def self.refuse_if_exceeded!(user)
    limit = ROLE_LIMITS.fetch(user.role.to_s)
    used  = current_total(user)
    if used >= limit
      raise QuotaExceededError.new(user_id: user.id, tokens_used: used, limit: limit)
    end

    used
  end
end
