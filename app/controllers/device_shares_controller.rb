# frozen_string_literal: true

class DeviceSharesController < ApplicationController
  include Paginatable
  include Sortable
  include TimeParseable

  SORTABLE_COLUMNS = %w[created_at updated_at expires_at status].freeze
  JSON_INCLUDES = {
    device: { only: %i[id name] },
    user: { only: %i[id username email] },
    permissions_group: { only: %i[id name see_screen see_system_info access_mouse access_keyboard access_terminal manage_power] }
  }.freeze

  before_action :authenticate_user!
  before_action :set_device_share, only: %i[show update destroy]
  before_action :authorize_show!, only: %i[show]
  before_action :authorize_manage!, only: %i[update destroy]

  # GET /device_shares
  def index
    shares = build_index_scope
    result = paginate(shares.order(created_at: :desc))

    render json: { items: result[:records].as_json(include: JSON_INCLUDES), meta: result[:meta] }, status: :ok
  end

  # GET /device_shares/me
  def me
    shares = build_me_scope
    result = paginate(apply_sort(shares.distinct, allowed_columns: SORTABLE_COLUMNS))

    render json: { items: result[:records].as_json(include: JSON_INCLUDES), meta: result[:meta] }, status: :ok
  end

  # GET /device_shares/:id
  def show
    render json: { item: @device_share.as_json(include: JSON_INCLUDES) }, status: :ok
  end

  # POST /device_shares
  def create
    device = Device.find_by(id: create_params[:device_id])

    unless device
      render json: { error: "Device not found" }, status: :not_found
      return
    end

    unless can_manage_device?(device)
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    attrs = build_share_attributes(create_params)
    return if performed? # user lookup failed

    @device_share = DeviceShare.new(attrs)

    if @device_share.save
      render json: { item: @device_share.as_json(include: JSON_INCLUDES) }, status: :created, location: @device_share
    else
      render json: @device_share.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /device_shares/:id
  def update
    attrs = build_share_attributes(update_params)
    return if performed? # user lookup failed

    if @device_share.update(attrs)
      render json: { item: @device_share.as_json(include: JSON_INCLUDES) }, status: :ok
    else
      render json: @device_share.errors, status: :unprocessable_entity
    end
  end

  # DELETE /device_shares/:id
  def destroy
    @device_share.destroy!
    head :no_content
  end

  private

  def set_device_share
    @device_share = DeviceShare.find_by(id: params[:id])
    render json: { error: "DeviceShare not found" }, status: :not_found unless @device_share
  end

  def authorize_show!
    return if current_user.admin?
    return if @device_share.device.user_id == current_user.id
    return if @device_share.user_id == current_user.id

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def authorize_manage!
    return if current_user.admin?
    return if @device_share.device.user_id == current_user.id

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def can_manage_device?(device)
    current_user.admin? || device.user_id == current_user.id
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Query Building
  # ──────────────────────────────────────────────────────────────────────────────

  def build_index_scope
    shares = DeviceShare.includes(:device, :user, :permissions_group)

    if current_user.admin?
      shares = shares.where(device_id: params[:device_id]) if params[:device_id].present?
      shares = shares.where(user_id: params[:user_id]) if params[:user_id].present?
    else
      shares = shares.joins(:device).where(
        "devices.user_id = ? OR device_shares.user_id = ?",
        current_user.id, current_user.id
      )
    end

    shares
  end

  def build_me_scope
    base = DeviceShare.joins(:device)
                      .where("devices.user_id = ? OR device_shares.user_id = ?", current_user.id, current_user.id)
                      .includes(:device, :user, :permissions_group)

    base = apply_direction_filter(base)
    base = apply_exact_filters(base)
    base = apply_user_email_filter(base)
    base = apply_time_filters(base)
    base
  end

  def apply_direction_filter(scope)
    direction = (params[:direction].presence || params[:owner]).to_s.downcase

    case direction
    when "incoming", "received", "shared"
      scope.where(device_shares: { user_id: current_user.id })
    when "outgoing", "owned", "me"
      scope.where(devices: { user_id: current_user.id })
    else
      scope
    end
  end

  def apply_exact_filters(scope)
    scope = scope.where(device_shares: { id: params[:id] }) if params[:id].present?
    scope = scope.where(device_shares: { device_id: params[:device_id] }) if params[:device_id].present?
    scope = scope.where(device_shares: { user_id: params[:user_id] }) if params[:user_id].present?
    scope = scope.where(device_shares: { permissions_group_id: params[:permissions_group_id] }) if params[:permissions_group_id].present?
    scope = scope.where(device_shares: { status: params[:status] }) if params[:status].present?
    scope = scope.where(device_shares: { expires_at: params[:expires_at] }) if params[:expires_at].present?
    scope
  end

  def apply_user_email_filter(scope)
    return scope unless params[:user_email].present?

    email = params[:user_email].to_s.strip.downcase
    scope.joins(:user).where("LOWER(users.email) = ?", email)
  end

  def apply_time_filters(scope)
    scope = apply_time_range_filter(scope, column: "device_shares.created_at", from_param: :created_from, to_param: :created_to)
    scope = apply_time_range_filter(scope, column: "device_shares.updated_at", from_param: :updated_from, to_param: :updated_to)
    scope = apply_time_range_filter(scope, column: "device_shares.expires_at", from_param: :expires_from, to_param: :expires_to)
    scope
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Attribute Building
  # ──────────────────────────────────────────────────────────────────────────────

  def build_share_attributes(permitted_params)
    attrs = permitted_params.to_h

    attrs = resolve_user_from_email(attrs)
    return attrs if performed?

    attrs = process_permissions_group_attributes(attrs)
    attrs
  end

  def resolve_user_from_email(attrs)
    return attrs if attrs["user_id"].present? || attrs["user_email"].blank?

    email = attrs.delete("user_email").to_s.strip.downcase
    user = User.find_by(email: email)

    unless user
      render json: { error: "User with email not found" }, status: :not_found
      return attrs
    end

    attrs["user_id"] = user.id
    attrs
  end

  def process_permissions_group_attributes(attrs)
    return attrs unless attrs["permissions_group_attributes"].present? && attrs["permissions_group_id"].blank?

    pg_attrs = attrs.delete("permissions_group_attributes")
    pg_attrs = pg_attrs.is_a?(ActionController::Parameters) ? pg_attrs.to_unsafe_h : pg_attrs
    pg_attrs["user_id"] = determine_permissions_group_owner(pg_attrs)
    attrs["permissions_group_attributes"] = pg_attrs
    attrs
  end

  def determine_permissions_group_owner(pg_attrs)
    (current_user.admin? && pg_attrs["user_id"].present?) ? pg_attrs["user_id"] : current_user.id
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Strong Parameters
  # ──────────────────────────────────────────────────────────────────────────────

  def create_params
    params.require(:device_share).permit(
      :device_id, :user_id, :user_email, :status, :expires_at, :permissions_group_id,
      permissions_group_attributes: %i[name see_screen see_system_info access_mouse access_keyboard access_terminal manage_power user_id]
    )
  end

  def update_params
    params.require(:device_share).permit(
      :user_id, :user_email, :status, :expires_at, :permissions_group_id,
      permissions_group_attributes: %i[name see_screen see_system_info access_mouse access_keyboard access_terminal manage_power user_id]
    )
  end
end
