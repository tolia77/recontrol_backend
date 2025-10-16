class CreateDevices < ActiveRecord::Migration[8.0]
  def change
    create_table :devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.string :status
      t.datetime :last_active_at

      t.timestamps
    end
  end
end
