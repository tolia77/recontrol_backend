class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [:show, :update, :destroy]
  before_action :authorize_admin!, only: [:index, :create, :destroy]
  before_action :authorize_access!, only: [:show, :update]

  # GET /users
  # Admin only
  def index
    users = User.all
    render json: users.as_json(except: [:password_digest])
  end

  # GET /users/:id
  # Admin can see anyone; user can see self
  def show
    render json: @user.as_json(except: [:password_digest])
  end

  # POST /users
  # Admin only
  def create
    user = User.new(user_params_create)
    if user.save
      render json: user.as_json(except: [:password_digest]), status: :created
    else
      render json: user.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /users/:id
  # Admin can update anyone; user can update self
  def update
    permitted = current_user.admin? ? user_params_update_admin : user_params_update_self
    if @user.update(permitted)
      render json: @user.as_json(except: [:password_digest])
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  # DELETE /users/:id
  # Admin only
  def destroy
    if @user.destroy
      head :no_content
    else
      render json: { error: "Failed to delete user" }, status: :unprocessable_entity
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def authorize_admin!
    render json: { error: "Forbidden" }, status: :forbidden unless current_user&.admin?
  end

  def authorize_access!
    return if current_user&.admin?
    render json: { error: "Forbidden" }, status: :forbidden unless @user.id == current_user&.id
  end

  # Strong params
  def user_params_create
    params.require(:user).permit(:username, :email, :password, :role)
  end

  def user_params_update_admin
    params.require(:user).permit(:username, :email, :password, :role)
  end

  def user_params_update_self
    params.require(:user).permit(:username, :email, :password)
  end
end

