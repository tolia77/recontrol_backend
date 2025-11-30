# frozen_string_literal: true

module Sortable
  extend ActiveSupport::Concern

  DEFAULT_SORT_COLUMN = "created_at"
  DEFAULT_SORT_DIRECTION = :desc

  private

  # Apply sorting to a scope with whitelisted columns
  # @param scope [ActiveRecord::Relation] the relation to sort
  # @param allowed_columns [Array<String>] permitted column names
  # @param default_column [String] fallback column if param invalid
  # @return [ActiveRecord::Relation] sorted relation
  def apply_sort(scope, allowed_columns:, default_column: DEFAULT_SORT_COLUMN)
    sort_column = validated_sort_column(allowed_columns, default_column)
    sort_direction = validated_sort_direction

    scope.order(sort_column.to_sym => sort_direction)
  end

  def validated_sort_column(allowed_columns, default_column)
    column = params[:sort_by].to_s
    allowed_columns.include?(column) ? column : default_column
  end

  def validated_sort_direction
    params[:sort_dir].to_s.downcase == "asc" ? :asc : DEFAULT_SORT_DIRECTION
  end
end

