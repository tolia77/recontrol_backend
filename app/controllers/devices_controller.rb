class DevicesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_device, only: %i[show update destroy]
  before_action :authorize_owner_or_admin, only: %i[show update destroy]

  # GET /devices
  def index
    p "INDEX"
    devices = Device.all

    # non-admins only see their devices
    unless current_user.admin?
      devices = devices.where(user_id: current_user.id)
    else
      devices = devices.where(user_id: params[:user_id]) if params[:user_id].present?
    end

    devices = devices.where(status: params[:status]) if params[:status].present?
    if params[:name].present?
      q = "%#{params[:name].to_s.downcase}%"
      devices = devices.where("LOWER(name) LIKE ?", q)
    end

    page = [params.fetch(:page, 1).to_i, 1].max
    per_page = [params.fetch(:per_page, 25).to_i, 1].max
    per_page = [per_page, 100].min

    total = devices.count
    devices = devices.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: { devices: devices, meta: { page: page, per_page: per_page, total: total } }, status: :ok  end

  # GET /devices/me
  def me
    # owned devices plus devices shared with the user
    owned = current_user.devices
    shared = Device.joins(:device_shares).where(device_shares: { user_id: current_user.id })
    devices = owned.or(shared) # union

    devices = devices.where(status: params[:status]) if params[:status].present?
    if params[:name].present?
      q = "%#{params[:name].to_s.downcase}%"
      devices = devices.where("LOWER(name) LIKE ?", q)
    end

    page = [params.fetch(:page, 1).to_i, 1].max
    per_page = [params.fetch(:per_page, 25).to_i, 1].max
    per_page = [per_page, 100].min

    total = devices.distinct.count
    devices = devices.distinct.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: devices, meta: { page: page, per_page: per_page, total: total }, status: :ok
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
end
