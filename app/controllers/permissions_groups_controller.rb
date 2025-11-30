# frozen_string_literal: true

class PermissionsGroupsController < ApplicationController
  include Paginatable

  JSON_FIELDS = %i[id name see_screen see_system_info access_mouse access_keyboard access_terminal manage_power user_id].freeze

  before_action :authenticate_user!
  before_action :set_permissions_group, only: %i[show update destroy]
  before_action :authorize_access!, only: %i[show update destroy]

  # GET /permissions_groups
  def index
    groups = current_user.admin? ? PermissionsGroup.all : PermissionsGroup.where(user_id: current_user.id)
    result = paginate(groups.order(created_at: :desc))

    render json: { items: result[:records].as_json(only: JSON_FIELDS), meta: result[:meta] }, status: :ok
  end

  # GET /permissions_groups/:id
  def show
    render json: { item: @permissions_group.as_json(only: JSON_FIELDS) }, status: :ok
  end

  # POST /permissions_groups
  def create
    attrs = create_params.to_h
    attrs[:user_id] = current_user.id unless current_user.admin? && attrs[:user_id].present?

    @permissions_group = PermissionsGroup.new(attrs)

    if @permissions_group.save
      render json: { item: @permissions_group.as_json(only: JSON_FIELDS) }, status: :created, location: @permissions_group
    else
      render json: @permissions_group.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /permissions_groups/:id
  def update
    if @permissions_group.update(update_params)
      render json: { item: @permissions_group.as_json(only: JSON_FIELDS) }, status: :ok
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

  def authorize_access!
    return if current_user.admin?
    return if @permissions_group.user_id == current_user.id

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def create_params
    params.require(:permissions_group).permit(:name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power, :user_id)
  end

  def update_params
    params.require(:permissions_group).permit(:name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power)
  end
end
