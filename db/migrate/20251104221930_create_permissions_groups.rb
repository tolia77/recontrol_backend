class CreatePermissionsGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :permissions_groups, id: :uuid do |t|
      t.boolean :see_screen
      t.boolean :see_system_info
      t.boolean :access_mouse
      t.boolean :access_keyboard
      t.boolean :access_terminal
      t.boolean :manage_power
      t.string :name
      t.references :user, null: false, foreign_key: true, type: :uuid

      t.timestamps
    end
  end
end
