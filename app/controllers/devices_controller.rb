class DevicesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_device, only: %i[show update destroy]
  before_action :authorize_owner_or_admin, only: %i[show update destroy]

  # GET /devices
  def index
    p "INDEX"
    # Admin-only access
    unless current_user.admin?
      render json: { error: "Forbidden" }, status: :forbidden and return
    end

    devices = Device.all

    # Optional scoping by user_id for admins
    devices = devices.where(user_id: params[:user_id]) if params[:user_id].present?

    # Filters
    devices = devices.where(status: params[:status]) if params[:status].present?
    if params[:name].present?
      q = "%#{params[:name].to_s.downcase}%"
      devices = devices.where("LOWER(name) LIKE ?", q)
    end
    if params[:last_active_from].present?
      from = parse_time(params[:last_active_from])
      devices = devices.where("last_active_at >= ?", from) if from
    end
    if params[:last_active_to].present?
      to = parse_time(params[:last_active_to])
      devices = devices.where("last_active_at <= ?", to) if to
    end

    # Pagination
    page = [params.fetch(:page, 1).to_i, 1].max
    per_page = [params.fetch(:per_page, 25).to_i, 1].max
    per_page = [per_page, 100].min

    total = devices.count
    devices = apply_sort(devices).offset((page - 1) * per_page).limit(per_page)

    render json: { devices: devices, meta: { page: page, per_page: per_page, total: total } }, status: :ok
  end

  # GET /devices/me
  def me
    # owned devices plus devices shared with the user (filtered by owner param)
    owned = current_user.devices
    shared = Device.where(id: DeviceShare.where(user_id: current_user.id).select(:device_id))

    owner_param = params[:owner].to_s.downcase
    devices =
      case owner_param
      when "me", "owned"
        owned
      when "shared"
        shared
      else
        owned.or(shared)
      end

    devices = devices.preload(:user)

    # Filters
    devices = devices.where(status: params[:status]) if params[:status].present?
    if params[:name].present?
      q = "%#{params[:name].to_s.downcase}%"
      devices = devices.where("LOWER(name) LIKE ?", q)
    end
    if params[:last_active_from].present?
      from = parse_time(params[:last_active_from])
      devices = devices.where("last_active_at >= ?", from) if from
    end
    if params[:last_active_to].present?
      to = parse_time(params[:last_active_to])
      devices = devices.where("last_active_at <= ?", to) if to
    end

    # Pagination
    page = [params.fetch(:page, 1).to_i, 1].max
    per_page = [params.fetch(:per_page, 25).to_i, 1].max
    per_page = [per_page, 100].min

    total = devices.distinct.count
    devices = apply_sort(devices.distinct).offset((page - 1) * per_page).limit(per_page)

    render json: {
      devices: devices.as_json(include: { user: { only: %i[username email] } }),
      meta: { page: page, per_page: per_page, total: total }
    }, status: :ok
  end

  # GET /devices/:id
  def show
    render json: @device, status: :ok
  end

  # POST /devices
  def create
    p "CREATE"
    # admins may assign user_id; regular users create for themselves
    if current_user.admin? && device_params[:user_id].present?
      device = Device.new(device_params)
    else
      device = current_user.devices.build(device_params.except(:user_id))
    end

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
    unless @device.user_id == current_user.id
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  def device_params
    params.fetch(:device, {}).permit(:name, :status, :user_id)
  end

  # Parse time string safely (ISO8601 or common formats). Returns Time or nil.
  def parse_time(val)
    return nil if val.blank?
    Time.iso8601(val) rescue (Time.zone.parse(val) rescue nil)
  end

  # Safe sorting helper for devices
  def apply_sort(scope)
    allowed = %w[created_at updated_at last_active_at name status]
    sort_by = params[:sort_by].to_s
    sort_by = allowed.include?(sort_by) ? sort_by : "created_at"
    dir = params[:sort_dir].to_s.downcase == "asc" ? :asc : :desc
    scope.order(sort_by.to_sym => dir)
  end
end
