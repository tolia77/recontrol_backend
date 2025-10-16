class CreateSessions < ActiveRecord::Migration[8.0]
  def change
    # Use UUID primary key for sessions and reference user/device by UUID
    create_table :sessions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :device, null: true, foreign_key: true, type: :uuid
      t.string :jti
      t.string :session_key
      t.string :client_type
      t.string :status
      t.datetime :expires_at

      t.timestamps
    end
  end
end
