# Add Lazada Channel — Change Summary

This document lists every file that was added or modified to introduce a **Lazada** inbox channel. The pattern mirrors the existing **LINE** channel, so if you need to extend or reverse any part, you can compare the two side-by-side.

---

## 1. What the user sees

1. Navigate to **Settings → Inboxes → Add Inbox**.
2. A new **Lazada** card appears in the "Choose Channel" grid (shopping-bag icon, title "Lazada", description "Integrate your Lazada shop").
3. Clicking the card opens a form titled **Lazada Channel** with the following fields:
   - Channel Name
   - App Profile Key
   - App Profile Secret
   - App Chat Key
   - App Chat Secret
4. Submitting the form calls `POST /api/v1/accounts/:account_id/inboxes` with `channel[type] = "lazada"`, which creates a `Channel::Lazada` record and its inbox, then redirects to the agent assignment step (same flow as LINE / Telegram).

---

## 2. Database

### New migration — `db/migrate/20260417000000_add_lazada_channel.rb`
Creates the `channel_lazada` table:

| Column               | Type     | Notes                      |
|----------------------|----------|----------------------------|
| `id`                 | bigint   | PK                         |
| `account_id`         | integer  | not null                   |
| `app_profile_key`    | string   | not null, **unique index** |
| `app_profile_secret` | string   | not null, encrypted*       |
| `app_chat_key`       | string   | not null                   |
| `app_chat_secret`    | string   | not null, encrypted*       |
| `created_at`         | datetime | not null                   |
| `updated_at`         | datetime | not null                   |

\*Secrets are encrypted at rest when `Chatwoot.encryption_configured?` is true (same guard used for LINE secrets).

### Schema snapshot — `db/schema.rb`
- Added matching `create_table "channel_lazada"` block.
- Bumped the schema `version` to `2026_04_17_000000`.

**Action required after pulling these changes:**
```bash
bundle exec rails db:migrate
```

---

## 3. Backend (Rails)

### New model — `app/models/channel/lazada.rb`
```ruby
class Channel::Lazada < ApplicationRecord
  include Channelable
  # encrypts :app_profile_secret, :app_chat_secret (when encryption is configured)
  self.table_name = 'channel_lazada'
  EDITABLE_ATTRS = [:app_profile_key, :app_profile_secret, :app_chat_key, :app_chat_secret].freeze
  validates :app_profile_key, uniqueness: true, presence: true
  validates :app_profile_secret, :app_chat_key, :app_chat_secret, presence: true
  def name = 'Lazada'
end
```

### `app/models/account.rb`
Added the reverse association so `Current.account.lazada_channels` works:
```ruby
has_many :lazada_channels, dependent: :destroy_async, class_name: '::Channel::Lazada'
```

### `app/controllers/api/v1/accounts/inboxes_controller.rb`
Two edits so the generic `#create` action accepts `type: 'lazada'`:
- Added `'lazada'` to `allowed_channel_types`.
- Added `'lazada' => Channel::Lazada` to `channel_type_from_params`.

### `app/helpers/api/v1/inboxes_helper.rb`
Added `'lazada' => Current.account.lazada_channels` to `account_channels_method` so the controller knows which relation to call `.create!` on.

> No webhook controller, jobs, or send/receive services were added. The work here only covers **persisting credentials**. Wiring up an actual Lazada webhook or outgoing message service is a separate task (see `docs/line-flow.md` for the template).

---

## 4. Frontend (Vue / Vuex)

### New form — `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Lazada.vue`
A near clone of `Line.vue`. Captures `channelName` + the four credential fields, all validated with `required`. On submit it dispatches the existing generic store action:
```js
this.$store.dispatch('inboxes/createChannel', {
  name: this.channelName?.trim(),
  channel: {
    type: 'lazada',
    app_profile_key: this.appProfileKey,
    app_profile_secret: this.appProfileSecret,
    app_chat_key: this.appChatKey,
    app_chat_secret: this.appChatSecret,
  },
});
```
On success it redirects to `settings_inboxes_add_agents`.

### `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue`
Imported the new `Lazada.vue` component and registered it under the key `lazada` in `channelViewList`. When the URL is `.../inboxes/new/lazada`, the factory renders our form.

### `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`
Added a new card entry to the `channelList` array:
```js
{
  key: 'lazada',
  title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.LAZADA.TITLE'),
  description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.LAZADA.DESCRIPTION'),
  icon: 'i-woot-lazada',
},
```

### `app/javascript/dashboard/components/widgets/ChannelItem.vue`
Added `'lazada'` to the list of always-active channel keys so the card is clickable (not greyed out). LINE and Telegram are treated the same way.

### Inbox type helpers — `app/javascript/dashboard/helper/inbox.js`
- Added `LAZADA: 'Channel::Lazada'` to `INBOX_TYPES`.
- Added entries for Lazada in both `INBOX_ICON_MAP_FILL` and `INBOX_ICON_MAP_LINE` (both point to `i-woot-lazada`). For now we reuse the custom woot icon for the filled variant; swap to a proper Remix Icon once Lazada is on the vendor's CDN.

### Channel-to-icon mapping — `app/javascript/dashboard/components-next/icon/provider.js`
Added `'Channel::Lazada': 'i-woot-lazada'` so any existing inbox list / header / badge that uses `useChannelIcon` picks up the right icon automatically.

### Icon definition — `theme/icons.js`
Registered a new `lazada` icon under the `woot` collection (exposed as the Tailwind class `i-woot-lazada`). The SVG is a simple shopping-bag outline with a check mark — acts as a placeholder until the official Lazada logo asset is added. The icon takes `currentColor`, so it follows the surrounding text color like every other woot channel icon.

### i18n — `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`
Three additions:
1. New `LAZADA_CHANNEL` block (used by `Lazada.vue`) — title, description, every field's label/placeholder, submit button, and an error message.
2. New `AUTH.CHANNEL.LAZADA` block — title/description used on the channel-picker card.
3. New `"LAZADA": "Lazada"` entry in the inbox-type label map used by other settings screens.

Only `en.json` was touched; other locales will pick this up via the community translation workflow (see `AGENTS.md`).

---

## 5. Files touched / added — quick index

### Added
- `db/migrate/20260417000000_add_lazada_channel.rb`
- `app/models/channel/lazada.rb`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Lazada.vue`
- `docs/add-lazada-ui.md` *(this file)*

### Modified
- `db/schema.rb`
- `app/models/account.rb`
- `app/controllers/api/v1/accounts/inboxes_controller.rb`
- `app/helpers/api/v1/inboxes_helper.rb`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`
- `app/javascript/dashboard/components/widgets/ChannelItem.vue`
- `app/javascript/dashboard/components-next/icon/provider.js`
- `app/javascript/dashboard/helper/inbox.js`
- `theme/icons.js`
- `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`

---

## 6. How to verify locally

1. Run the migration: `bundle exec rails db:migrate`.
2. Start the dev server (e.g. `pnpm dev` or `overmind start -f ./Procfile.dev`).
3. In the dashboard, go to **Settings → Inboxes → Add Inbox** and confirm the **Lazada** card renders with the shopping-bag icon.
4. Click the card, fill in the four credentials + channel name, and submit.
5. Expect a `201 Created` from `POST /api/v1/accounts/:account_id/inboxes` and a new row in `channel_lazada` (`Channel::Lazada.last` from a Rails console).
6. Confirm the new inbox is visible in the inbox list with the Lazada icon next to its name.

---

## 7. Not included (intentional)

The current change only stores credentials. The following pieces — documented in `docs/line-flow.md` as the reference template — are **not yet implemented** and will be future work:

- Lazada webhook route (`config/routes.rb`) + controller (`Webhooks::LazadaController`)
- Signature-verification job (`Webhooks::LazadaEventsJob`)
- Incoming message service (`Lazada::IncomingMessageService`)
- Outgoing message service (`Lazada::SendOnLazadaService`) + registration in `SendReplyJob::CHANNEL_SERVICES`
- Inbox `callback_webhook_url` entry in `app/models/inbox.rb`
- Lazada API SDK/client inside `Channel::Lazada#client`

When implementing those, mirror the LINE implementation file-for-file — the Channel model already carries the credentials needed to authenticate.
