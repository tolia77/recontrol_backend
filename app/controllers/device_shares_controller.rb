class DeviceSharesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_device_share, only: %i[show update destroy]
  before_action :authorize_show!, only: %i[show]
  before_action :authorize_manage!, only: %i[update destroy]

  # GET /device_shares
  # Admins see all (optionally filtered). Regular users see shares they own (as device owner) or receive.
  def index
    shares = DeviceShare.includes(:device, :user, :permissions_group)

    if current_user.admin?
      shares = shares.where(device_id: params[:device_id]) if params[:device_id].present?
      shares = shares.where(user_id: params[:user_id]) if params[:user_id].present?
    else
      # device owner or recipient
      shares = shares.joins(:device).where("devices.user_id = ? OR device_shares.user_id = ?", current_user.id, current_user.id)
    end

    page = [params.fetch(:page, 1).to_i, 1].max
    per_page = [params.fetch(:per_page, 25).to_i, 1].max
    per_page = [per_page, 100].min

    total = shares.count
    shares = shares.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: shares.as_json(include: { device: { only: [:id, :name] }, user: { only: [:id, :username, :email] }, permissions_group: { only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power] } }),
      meta: { page: page, per_page: per_page, total: total }
    }, status: :ok
  end

  # GET /device_shares/:id
  def show
    render json: {
      item: @device_share.as_json(include: { device: { only: [:id, :name] }, user: { only: [:id, :username, :email] }, permissions_group: { only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power] } })
    }, status: :ok
  end

  # POST /device_shares
  def create
    # Only device owner or admin can create shares
    device = Device.find_by(id: create_params[:device_id])
    unless device
      render json: { error: "Device not found" }, status: :not_found and return
    end

    unless current_user.admin? || device.user_id == current_user.id
      render json: { error: "Forbidden" }, status: :forbidden and return
    end

    # Build base attributes
    attrs = create_params.to_h

    # If user email provided instead of id, resolve to user_id
    if attrs["user_id"].blank? && attrs["user_email"].present?
      email = attrs.delete("user_email").to_s.strip.downcase
      user = User.find_by(email: email)
      unless user
        render json: { error: "User with email not found" }, status: :not_found and return
      end
      attrs["user_id"] = user.id
    end

    # Handle nested permissions group attributes
    if attrs["permissions_group_attributes"].present? && attrs["permissions_group_id"].blank?
      pg_attrs = attrs.delete("permissions_group_attributes")
      # Force owner of permissions group: current_user unless admin explicitly sets user_id
      pg_attrs = pg_attrs.is_a?(ActionController::Parameters) ? pg_attrs.to_unsafe_h : pg_attrs
      pg_attrs["user_id"] = (current_user.admin? && pg_attrs["user_id"].present?) ? pg_attrs["user_id"] : current_user.id
      attrs["permissions_group_attributes"] = pg_attrs
    end

    @device_share = DeviceShare.new(attrs)

    if @device_share.save
      render json: {
        item: @device_share.as_json(include: { device: { only: [:id, :name] }, user: { only: [:id, :username, :email] }, permissions_group: { only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power] } })
      }, status: :created, location: @device_share
    else
      render json: @device_share.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /device_shares/:id
  def update
    # Only device owner or admin can update a share
    attrs = update_params.to_h

    # If user email provided instead of id, resolve to user_id
    if attrs["user_id"].blank? && attrs["user_email"].present?
      email = attrs.delete("user_email").to_s.strip.downcase
      user = User.find_by(email: email)
      unless user
        render json: { error: "User with email not found" }, status: :not_found and return
      end
      attrs["user_id"] = user.id
    end

    if attrs["permissions_group_attributes"].present? && attrs["permissions_group_id"].blank?
      pg_attrs = attrs.delete("permissions_group_attributes")
      pg_attrs = pg_attrs.is_a?(ActionController::Parameters) ? pg_attrs.to_unsafe_h : pg_attrs
      pg_attrs["user_id"] = (current_user.admin? && pg_attrs["user_id"].present?) ? pg_attrs["user_id"] : current_user.id
      attrs["permissions_group_attributes"] = pg_attrs
    end

    if @device_share.update(attrs)
      render json: {
        item: @device_share.as_json(include: { device: { only: [:id, :name] }, user: { only: [:id, :username, :email] }, permissions_group: { only: [:id, :name, :see_screen, :see_system_info, :access_mouse, :access_keyboard, :access_terminal, :manage_power] } })
      }, status: :ok
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

    unless (@device_share.device.user_id == current_user.id) || (@device_share.user_id == current_user.id)
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  def authorize_manage!
    return if current_user.admin?

    unless @device_share.device.user_id == current_user.id
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  # Strong params
  def create_params
    params.require(:device_share).permit(
      :device_id,
      :user_id,
      :user_email,
      :status,
      :expires_at,
      :permissions_group_id,
      permissions_group_attributes: [
        :name,
        :see_screen,
        :see_system_info,
        :access_mouse,
        :access_keyboard,
        :access_terminal,
        :manage_power,
        :user_id
      ]
    )
  end

  def update_params
    params.require(:device_share).permit(
      :user_id,
      :user_email,
      :status,
      :expires_at,
      :permissions_group_id,
      permissions_group_attributes: [
        :name,
        :see_screen,
        :see_system_info,
        :access_mouse,
        :access_keyboard,
        :access_terminal,
        :manage_power,
        :user_id
      ]
    )
  end
end
