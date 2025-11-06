class DeviceSerializer < ActiveModel::Serializer
  attributes :id, :name, :status, :last_active_at, :created_at, :updated_at, :user, :user_id

  def user
    return unless object.user
    {
      id: object.user.id,
      username: object.user.username,
      email: object.user.email,
      role: object.user.role
    }
  end
end
