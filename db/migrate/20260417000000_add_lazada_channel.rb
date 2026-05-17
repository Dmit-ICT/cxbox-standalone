class AddLazadaChannel < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_lazada do |t|
      t.integer :account_id, null: false
      t.string :app_profile_key, null: false
      t.string :app_profile_secret, null: false
      t.string :app_chat_key, null: false
      t.string :app_chat_secret, null: false
      t.timestamps
    end

    add_index :channel_lazada, :app_profile_key, unique: true
  end
end
