class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    # Ensure pgcrypto (gen_random_uuid) is available for UUID defaults
    enable_extension 'pgcrypto' unless extension_enabled?('pgcrypto')
    # Use UUID primary keys for users
    create_table :users, id: :uuid do |t|
      t.string :username
      t.string :email
      t.string :password_digest
      t.integer :role

      t.timestamps
    end
  end
end
