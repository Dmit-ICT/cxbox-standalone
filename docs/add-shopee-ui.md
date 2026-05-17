# Add Shopee Inbox Channel

This document summarizes every change made to introduce a **Shopee** inbox channel, mirroring the pattern used by the LINE / Lazada channels.

## Feature summary

1. New **Shopee** card on the *Add Inbox* screen with the Shopee icon, title “Shopee”, and description “Integrate your Shopee shop”.
2. Clicking the card shows a configuration form with:
   - **Channel Name** (required)
   - **App Partner Id** (required, unique)
   - **App Partner Key** (required, stored encrypted when encryption is configured)
   - **Shop Country** dropdown (required) — Thailand, Singapore, Malaysia, Indonesia, Vietnam, Philippines, Taiwan, Brazil, Mexico, Colombia, Chile, Chinese Mainland
   - **Create Shopee Channel** submit button
3. Submission persists a row in the new `channel_shopee` table, then routes to the “add agents” step (same flow as other channels).

## Backend changes

### 1. Database migration

`db/migrate/20260417010000_add_shopee_channel.rb`

```ruby
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
```

### 2. Model

`app/models/channel/shopee.rb`

- Includes `Channelable` (gives `inbox` association, account link, helpers).
- Encrypts `app_partner_key` when `Chatwoot.encryption_configured?`.
- `EDITABLE_ATTRS = [:app_partner_id, :app_partner_key, :shop_country]`.
- Validates presence of all three credential fields; `app_partner_id` is unique.
- `shop_country` must be one of the 12 values in `Channel::Shopee::SHOP_COUNTRIES`.

```ruby
SHOP_COUNTRIES = %w[
  thailand singapore malaysia indonesia vietnam philippines
  taiwan brazil mexico colombia chile chinese_mainland
].freeze
```

### 3. Account association

`app/models/account.rb`

```ruby
has_many :shopee_channels, dependent: :destroy_async, class_name: '::Channel::Shopee'
```

### 4. Inboxes controller

`app/controllers/api/v1/accounts/inboxes_controller.rb`

- `allowed_channel_types` now includes `'shopee'`.
- `channel_type_from_params` maps `'shopee' => Channel::Shopee`.

### 5. Inboxes helper

`app/helpers/api/v1/inboxes_helper.rb`

- `account_channels_method` maps `'shopee' => Current.account.shopee_channels`.

### 6. Schema

`db/schema.rb`

- Version bumped to `2026_04_17_010000`.
- Added `create_table "channel_shopee"` with the unique index on `app_partner_id`.

## Frontend changes

### 1. Channel form component

`app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Shopee.vue`

- Mirrors `Lazada.vue`.
- Fields: `channelName`, `appPartnerId`, `appPartnerKey`, `shopCountry` (all required via `@vuelidate/core`).
- `shopCountry` is a `<select>` with the 12 countries; values match backend `SHOP_COUNTRIES` slugs.
- Dispatches `inboxes/createChannel` with:
  ```js
  {
    name: channelName.trim(),
    channel: {
      type: 'shopee',
      app_partner_id,
      app_partner_key,
      shop_country,
    },
  }
  ```
- On success navigates to `settings_inboxes_add_agents`.

### 2. Channel factory

`app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue`

- Import `Shopee from './channels/Shopee.vue'` and register it under key `shopee`.

### 3. Channel picker card

`app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`

- New entry:
  ```js
  {
    key: 'shopee',
    title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.SHOPEE.TITLE'),
    description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.SHOPEE.DESCRIPTION'),
    icon: 'i-woot-shopee',
  }
  ```

### 4. Enable card click

`app/javascript/dashboard/components/widgets/ChannelItem.vue`

- `'shopee'` added to the `isActive` keys so the card is clickable.

### 5. Inbox type + icon mapping

`app/javascript/dashboard/helper/inbox.js`

- `INBOX_TYPES.SHOPEE = 'Channel::Shopee'`.
- Both `INBOX_ICON_MAP_FILL` and `INBOX_ICON_MAP_LINE` map `INBOX_TYPES.SHOPEE` to `'i-woot-shopee'`.

`app/javascript/dashboard/components-next/icon/provider.js`

- `channelTypeIconMap['Channel::Shopee'] = 'i-woot-shopee'`.

### 6. Custom icon

`theme/icons.js`

- New `shopee` icon added to the `woot` icon set (shopping bag with a stylized “S” glyph). Exposed via UnoCSS as `i-woot-shopee`.

### 7. Localization

`app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`

- New `INBOX_MGMT.ADD.SHOPEE_CHANNEL` block with title, description, field labels/placeholders, country options, submit button, and API error message.
- `INBOX_MGMT.ADD.AUTH.CHANNEL.SHOPEE` block for the picker card.
- `INBOX_MGMT.CHANNEL_TYPES.SHOPEE = 'Shopee'`.

## How to run / verify

### Migration

```bash
bundle exec rails db:migrate
```

Verify:

```bash
PGPASSWORD='Password1234!' psql -h localhost -p 5433 -U postgres -d standalone_db \
  -c "\d channel_shopee"
```

Expected columns: `id, account_id, app_partner_id, app_partner_key, shop_country, created_at, updated_at` plus unique index on `app_partner_id`.

### Start the app

```bash
overmind start -f ./Procfile.dev
```

Navigate to **Settings → Inboxes → Add Inbox**, click the **Shopee** card, fill in the form and submit. A new row should appear:

```bash
PGPASSWORD='Password1234!' psql -h localhost -p 5433 -U postgres -d standalone_db \
  -c "SELECT id, account_id, app_partner_id, shop_country, created_at FROM channel_shopee ORDER BY id DESC LIMIT 1;"
```

## Deliberately out of scope

The following are **not** implemented yet – they can be added later when the actual Shopee integration is wired up:

- Shopee Open Platform OAuth / webhook registration.
- Outbound / inbound message services (`SendOnShopeeService`, `Shopee::IncomingMessageService`, event handlers).
- Edit / display components under `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/` for updating existing Shopee inboxes.
- Encrypted field rotation / attachment handling specific to Shopee.

## Files touched

Added:
- `db/migrate/20260417010000_add_shopee_channel.rb`
- `app/models/channel/shopee.rb`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Shopee.vue`
- `docs/add-shopee-ui.md`

Modified:
- `app/models/account.rb`
- `app/controllers/api/v1/accounts/inboxes_controller.rb`
- `app/helpers/api/v1/inboxes_helper.rb`
- `db/schema.rb`
- `theme/icons.js`
- `app/javascript/dashboard/helper/inbox.js`
- `app/javascript/dashboard/components-next/icon/provider.js`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`
- `app/javascript/dashboard/components/widgets/ChannelItem.vue`
- `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`
