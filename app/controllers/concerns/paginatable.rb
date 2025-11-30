# frozen_string_literal: true

module Paginatable
  extend ActiveSupport::Concern

  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  private

  def paginate(scope)
    page = normalized_page
    per_page = normalized_per_page
    total = scope.count

    records = scope.offset((page - 1) * per_page).limit(per_page)

    {
      records: records,
      meta: { page: page, per_page: per_page, total: total }
    }
  end

  def normalized_page
    [params.fetch(:page, DEFAULT_PAGE).to_i, 1].max
  end

  def normalized_per_page
    [[params.fetch(:per_page, DEFAULT_PER_PAGE).to_i, 1].max, MAX_PER_PAGE].min
  end

  def pagination_meta
    {
      page: normalized_page,
      per_page: normalized_per_page
    }
  end
end

