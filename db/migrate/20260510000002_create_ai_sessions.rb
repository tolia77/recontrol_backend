class CreateAiSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_sessions, id: :uuid, default: 'gen_random_uuid()' do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :device, type: :uuid, null: true,
                            foreign_key: { on_delete: :nullify }
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: true
      t.integer :turn_count, null: false, default: 0
      t.bigint :input_tokens, null: true
      t.bigint :output_tokens, null: true
      t.string :model, null: false
      t.string :stop_reason, null: true
      t.timestamps
    end

    add_index :ai_sessions, %i[user_id started_at]
  end
end
