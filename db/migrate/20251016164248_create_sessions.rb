class CreateSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :device, null: true, foreign_key: true
      t.string :jti
      t.string :session_key
      t.string :client_type
      t.string :status
      t.datetime :expires_at

      t.timestamps
    end
  end
end
