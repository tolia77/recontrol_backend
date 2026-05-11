class CreateAiUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_usages, id: :uuid, default: 'gen_random_uuid()' do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.date :usage_date, null: false
      t.bigint :tokens_used, null: false, default: 0
      t.timestamps
    end

    add_index :ai_usages, %i[user_id usage_date], unique: true,
              name: "index_ai_usages_on_user_and_date"
  end
end
