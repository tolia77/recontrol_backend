class AddPlatformInfoToDevices < ActiveRecord::Migration[8.0]
  def change
    add_column :devices, :platform_name, :string
    add_column :devices, :platform_version, :string
  end
end
