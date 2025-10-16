class CreateDevices < ActiveRecord::Migration[8.0]
  def change
    # Use UUID primary key for devices and reference user by UUID
    create_table :devices, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status
      t.datetime :last_active_at

      t.timestamps
    end
  end
end
