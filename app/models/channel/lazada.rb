# == Schema Information
#
# Table name: channel_lazada
#
#  id                 :bigint           not null, primary key
#  app_chat_key       :string           not null
#  app_chat_secret    :string           not null
#  app_profile_key    :string           not null
#  app_profile_secret :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :integer          not null
#
# Indexes
#
#  index_channel_lazada_on_app_profile_key  (app_profile_key) UNIQUE
#

class Channel::Lazada < ApplicationRecord
  include Channelable

  if Chatwoot.encryption_configured?
    encrypts :app_profile_secret
    encrypts :app_chat_secret
  end

  self.table_name = 'channel_lazada'
  EDITABLE_ATTRS = [:app_profile_key, :app_profile_secret, :app_chat_key, :app_chat_secret].freeze

  validates :app_profile_key, uniqueness: true, presence: true
  validates :app_profile_secret, presence: true
  validates :app_chat_key, presence: true
  validates :app_chat_secret, presence: true

  def name
    'Lazada'
  end
end
