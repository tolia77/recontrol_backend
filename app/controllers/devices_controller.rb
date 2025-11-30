# frozen_string_literal: true

class DevicesController < ApplicationController
  include Paginatable
  include Sortable
  include TimeParseable

  SORTABLE_COLUMNS = %w[created_at updated_at last_active_at name status].freeze

  before_action :authenticate_user!
  before_action :set_device, only: %i[show update destroy]
  before_action :authorize_owner_or_admin, only: %i[show update destroy]

  # GET /devices
  def index
    unless current_user.admin?
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    devices = build_device_query(Device.all)
    result = paginate(apply_sort(devices, allowed_columns: SORTABLE_COLUMNS))

    render json: { devices: result[:records], meta: result[:meta] }, status: :ok
  end

  # GET /devices/me
  def me
    devices = build_user_devices_scope
    devices = build_device_query(devices.preload(:user))
    result = paginate(apply_sort(devices.distinct, allowed_columns: SORTABLE_COLUMNS))

    render json: {
      devices: result[:records].as_json(include: { user: { only: %i[username email] } }),
      meta: result[:meta]
    }, status: :ok
  end

  # GET /devices/:id
  def show
    render json: @device, status: :ok
  end

  # POST /devices
  def create
    device = build_device

    if device.save
      render json: device, status: :created, location: device
    else
      render json: device.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /devices/:id
  def update
    if @device.update(device_params.except(:user_id))
      render json: @device, status: :ok
    else
      render json: @device.errors, status: :unprocessable_entity
    end
  end

  # DELETE /devices/:id
  def destroy
    @device.destroy!
    head :no_content
  end

  private

  def set_device
    @device = Device.find_by(id: params[:id])
    render json: { error: "Device not found" }, status: :not_found unless @device
  end

  def authorize_owner_or_admin
    return if current_user.admin?
    return if @device.user_id == current_user.id

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def device_params
    params.fetch(:device, {}).permit(:name, :status, :user_id)
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Query Building
  # ──────────────────────────────────────────────────────────────────────────────

  def build_user_devices_scope
    owned = current_user.devices
    shared = Device.where(id: DeviceShare.where(user_id: current_user.id).select(:device_id))

    case params[:owner].to_s.downcase
    when "me", "owned"
      owned
    when "shared"
      shared
    else
      owned.or(shared)
    end
  end

  def build_device_query(scope)
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = apply_device_filters(scope)
    scope
  end

  def apply_device_filters(scope)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = apply_name_filter(scope)
    scope = apply_time_range_filter(scope, column: :last_active_at, from_param: :last_active_from, to_param: :last_active_to)
    scope
  end

  def apply_name_filter(scope)
    return scope unless params[:name].present?

    pattern = "%#{params[:name].to_s.downcase}%"
    scope.where("LOWER(name) LIKE ?", pattern)
  end

  def build_device
    if current_user.admin? && device_params[:user_id].present?
      Device.new(device_params)
    else
      current_user.devices.build(device_params.except(:user_id))
    end
  end
end
