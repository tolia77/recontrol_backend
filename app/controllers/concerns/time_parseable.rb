# frozen_string_literal: true

module TimeParseable
  extend ActiveSupport::Concern

  private

  # Parse time string safely (ISO8601 or common formats)
  # @param value [String] the time string to parse
  # @return [Time, nil] parsed time or nil if invalid
  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value)
  rescue ArgumentError
    Time.zone.parse(value)
  rescue ArgumentError, TypeError
    nil
  end

  # Apply time range filter to a scope
  # @param scope [ActiveRecord::Relation] the relation to filter
  # @param column [Symbol] the column to filter on
  # @param from_param [String] param name for 'from' boundary
  # @param to_param [String] param name for 'to' boundary
  # @return [ActiveRecord::Relation] filtered relation
  def apply_time_range_filter(scope, column:, from_param:, to_param:)
    if params[from_param].present?
      from_time = parse_time(params[from_param])
      scope = scope.where("#{column} >= ?", from_time) if from_time
    end

    if params[to_param].present?
      to_time = parse_time(params[to_param])
      scope = scope.where("#{column} <= ?", to_time) if to_time
    end

    scope
  end
end

