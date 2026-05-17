# == Schema Information
#
# Table name: channel_shopee
#
#  id              :bigint           not null, primary key
#  app_partner_key :string           not null
#  shop_country    :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :integer          not null
#  app_partner_id  :string           not null
#
# Indexes
#
#  index_channel_shopee_on_app_partner_id  (app_partner_id) UNIQUE
#

class Channel::Shopee < ApplicationRecord
  include Channelable

  encrypts :app_partner_key if Chatwoot.encryption_configured?

  self.table_name = 'channel_shopee'
  EDITABLE_ATTRS = [:app_partner_id, :app_partner_key, :shop_country].freeze

  SHOP_COUNTRIES = %w[
    thailand
    singapore
    malaysia
    indonesia
    vietnam
    philippines
    taiwan
    brazil
    mexico
    colombia
    chile
    chinese_mainland
  ].freeze

  validates :app_partner_id, uniqueness: true, presence: true
  validates :app_partner_key, presence: true
  validates :shop_country, presence: true, inclusion: { in: SHOP_COUNTRIES }

  def name
    'Shopee'
  end
end
