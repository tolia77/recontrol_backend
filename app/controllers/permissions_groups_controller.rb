class PermissionsGroupsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_permissions_group, only: %i[show update destroy]
  before_action :authorize_show!, only: %i[show]
  before_action :authorize_manage!, only: %i[update destroy]

  # GET /permissions_groups
  # Admins see all; regular users see only theirs
  def index
    groups = PermissionsGroup.all
    groups = groups.where(user_id: current_user.id) unless current_user.admin?

    page = [params.fetch(:page, 1).to_i, 1].max
    per_page = [params.fetch(:per_page, 25).to_i, 1].max
    per_page = [per_page, 100].min

    total = groups.count
    groups = groups.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: groups.as_json(only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power, :user_id]),
      meta: { page: page, per_page: per_page, total: total }
    }, status: :ok
  end

  # GET /permissions_groups/:id
  def show
    render json: {
      item: @permissions_group.as_json(only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power, :user_id])
    }, status: :ok
  end

  # POST /permissions_groups
  def create
    attrs = create_params
    attrs = attrs.merge(user_id: current_user.id) unless current_user.admin? && attrs[:user_id].present?

    @permissions_group = PermissionsGroup.new(attrs)

    if @permissions_group.save
      render json: { item: @permissions_group.as_json(only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power, :user_id]) }, status: :created, location: @permissions_group
    else
      render json: @permissions_group.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /permissions_groups/:id
  def update
    attrs = update_params

    if @permissions_group.update(attrs)
      render json: { item: @permissions_group.as_json(only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power, :user_id]) }, status: :ok
    else
      render json: @permissions_group.errors, status: :unprocessable_entity
    end
  end

  # DELETE /permissions_groups/:id
  def destroy
    @permissions_group.destroy!
    head :no_content
  end

  private
  def set_permissions_group
    @permissions_group = PermissionsGroup.find_by(id: params[:id])
    render json: { error: "PermissionsGroup not found" }, status: :not_found unless @permissions_group
  end

  def authorize_show!
    return if current_user.admin?

    unless @permissions_group.user_id == current_user.id
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  def authorize_manage!
    return if current_user.admin?

    unless @permissions_group.user_id == current_user.id
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  def create_params
    params.require(:permissions_group).permit(:name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power, :user_id)
  end

  def update_params
    params.require(:permissions_group).permit(:name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power)
  end
end

