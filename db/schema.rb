# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_11_04_222055) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "device_shares", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "device_id", null: false
    t.uuid "user_id", null: false
    t.uuid "permissions_group_id", null: false
    t.string "status"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id"], name: "index_device_shares_on_device_id"
    t.index ["permissions_group_id"], name: "index_device_shares_on_permissions_group_id"
    t.index ["user_id"], name: "index_device_shares_on_user_id"
  end

  create_table "devices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "name"
    t.string "status"
    t.datetime "last_active_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_devices_on_user_id"
  end

  create_table "permissions_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "see_screen"
    t.boolean "see_system_info"
    t.boolean "access_mouse"
    t.boolean "access_keyboard"
    t.boolean "access_terminal"
    t.boolean "manage_power"
    t.string "name"
    t.uuid "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_permissions_groups_on_user_id"
  end

  create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "device_id"
    t.string "jti"
    t.string "session_key"
    t.string "client_type"
    t.string "status"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id"], name: "index_sessions_on_device_id"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "username"
    t.string "email"
    t.string "password_digest"
    t.integer "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "device_shares", "devices"
  add_foreign_key "device_shares", "permissions_groups"
  add_foreign_key "device_shares", "users"
  add_foreign_key "devices", "users"
  add_foreign_key "permissions_groups", "users"
  add_foreign_key "sessions", "devices"
  add_foreign_key "sessions", "users"
end
