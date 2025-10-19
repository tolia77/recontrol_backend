require_dependency Rails.root.join("app", "utils", "jwt_utils.rb").to_s

class ApplicationController < ActionController::API
  include JWTUtils
  include ActionController::Cookies
  include Authentication

  def authenticate_user!
    unless authorized?
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def check_is_admin!
    unless current_user&.admin?
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end
end
