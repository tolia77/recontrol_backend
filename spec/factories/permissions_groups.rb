FactoryBot.define do
  factory :permissions_group do
    see_screen { false }
    see_system_info { false }
    access_mouse { false }
    access_keyboard { false }
    access_terminal { false }
    manage_power { false }
    name { "MyString" }
    user { nil }
  end
end
