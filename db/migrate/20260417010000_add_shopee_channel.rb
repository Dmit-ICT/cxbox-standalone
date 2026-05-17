class AddShopeeChannel < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_shopee do |t|
      t.integer :account_id, null: false
      t.string :app_partner_id, null: false
      t.string :app_partner_key, null: false
      t.string :shop_country, null: false
      t.timestamps
    end

    add_index :channel_shopee, :app_partner_id, unique: true
  end
end
