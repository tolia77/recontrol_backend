class CreateDeviceShares < ActiveRecord::Migration[8.0]
  def change
    create_table :device_shares, id: :uuid do |t|
      t.references :device, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :permissions_group, null: false, foreign_key: true, type: :uuid
      t.string :status
      t.datetime :expires_at

      t.timestamps
    end
  end
end
