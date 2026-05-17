# Telegram Channel Message Flow

This document describes the complete message lifecycle for the Telegram channel in Chatwoot — from a user sending a message in the Telegram app through to it appearing in the agent's inbox, and then the reverse path for agent replies back to the Telegram user.

---

## Overview

```
Telegram User ──────────────────────────────────────── Agent (Chatwoot)
    │                                                        │
    │  [sends message]                                       │
    │──► Telegram Platform ──► Webhook ──► Chatwoot Backend ──► │ (displayed in UI)
    │                                                        │
    │                                              [agent replies]
    │◄── Telegram Platform ◄── Bot API ◄── Chatwoot Backend ◄──│
```

---

## Inbox Setup (One-Time, on Channel Creation)

When an agent creates a Telegram inbox in Chatwoot, the `Channel::Telegram` model performs two actions immediately on save:

**1. Validate the bot token**

Calls `GET https://api.telegram.org/bot{token}/getMe` to confirm the token is valid and stores the bot's username in `bot_name`.

**2. Register the webhook with Telegram**

Calls Telegram's `setWebhook` API to tell Telegram where to deliver messages:

```ruby
# app/models/channel/telegram.rb
def setup_telegram_webhook
  HTTParty.post("#{telegram_api_url}/deleteWebhook")
  HTTParty.post("#{telegram_api_url}/setWebhook",
    body: { url: "#{FRONTEND_URL}/webhooks/telegram/#{bot_token}" })
end
```

The registered webhook URL is:
```
POST https://{your-chatwoot-domain}/webhooks/telegram/{bot_token}
```

From this point on, every message sent to the bot will be `POST`-ed by Telegram to that URL automatically.

**File:** `app/models/channel/telegram.rb`

---

## Part 1 — Incoming Flow (Telegram User → Chatwoot Agent)

### Step 1: Telegram delivers the webhook

When a user sends a message to the bot, Telegram's platform makes an HTTP `POST` to the registered webhook URL:

```
POST /webhooks/telegram/:bot_token
```

The `:bot_token` in the URL is used to identify which `Channel::Telegram` inbox this message belongs to. There is no signature header — Telegram secures the channel by embedding the secret token directly in the URL.

**File:** `config/routes.rb`
```ruby
post 'webhooks/telegram/:bot_token', to: 'webhooks/telegram#process_payload'
```

---

### Step 2: Controller acknowledges immediately

`Webhooks::TelegramController#process_payload` enqueues a background job and immediately responds `200 OK` to Telegram. This prevents Telegram from retrying due to slow processing.

**File:** `app/controllers/webhooks/telegram_controller.rb`
```ruby
def process_payload
  Webhooks::TelegramEventsJob.perform_later(params.to_unsafe_hash)
  head :ok
end
```

---

### Step 3: Background job looks up the channel and routes the event

`Webhooks::TelegramEventsJob` performs:

1. **Channel lookup** — finds `Channel::Telegram` by `bot_token` from the route params. Stops if not found.
2. **Account activity check** — stops if the account is inactive or suspended.
3. **Event routing** — inspects the payload to decide which service to call:

```ruby
# app/jobs/webhooks/telegram_events_job.rb
def process_event_params(channel, params)
  return unless params[:telegram]

  if params.dig(:telegram, :edited_message).present? ||
     params.dig(:telegram, :edited_business_message).present?
    Telegram::UpdateMessageService.new(...).perform   # ← message edit
  else
    Telegram::IncomingMessageService.new(...).perform # ← new message
  end
end
```

| Telegram event | Service called |
|---|---|
| New message / callback query | `Telegram::IncomingMessageService` |
| Edited message / edited business message | `Telegram::UpdateMessageService` |

> **Note on Business Bots:** Telegram's Business Bot feature allows Telegram Premium users to link a business account to a bot. In this mode, messages from the business owner's own Telegram client appear as `business_message` events instead of `message` events. The job handles this by normalising `business_message` → `message` before processing.

**File:** `app/jobs/webhooks/telegram_events_job.rb`

---

### Step 4: Parse the event and resolve the contact

`Telegram::IncomingMessageService#perform` uses helpers from the `Telegram::ParamHelpers` module.

#### 4a. Filter out group chats

Chatwoot only supports private (1-to-1) conversations. Group chats are silently dropped:

```ruby
return unless private_message?
# private_message? checks: params.dig(:message, :chat, :type) == 'private'
# OR it is a callback_query (inline keyboard button press)
```

#### 4b. Find or create the Chatwoot Contact

`ContactInboxWithContactBuilder` uses the Telegram `from.id` (or `chat.id` for Business Bots) as `source_id`:

```ruby
::ContactInboxWithContactBuilder.new(
  source_id: telegram_params_from_id,   # Telegram user ID
  inbox: inbox,
  contact_attributes: {
    name: "#{first_name} #{last_name}",
    additional_attributes: {
      username: telegram_username,
      language_code: language_code,
      social_telegram_user_id: from_id,
      social_telegram_user_name: username
    }
  }
).perform
```

#### 4c. Fetch and store the contact's profile photo (async)

If the contact has no avatar yet, an async job fetches it from Telegram's `getUserProfilePhotos` API:

```ruby
avatar_url = inbox.channel.get_telegram_profile_image(telegram_params_from_id)
::Avatar::AvatarFromUrlJob.perform_later(@contact, avatar_url) if avatar_url
```

#### 4d. Find or create the Conversation

```ruby
@conversation = if @inbox.lock_to_single_conversation
                  @contact_inbox.conversations.last
                else
                  @contact_inbox.conversations.where.not(status: :resolved).last
                end
@conversation ||= ::Conversation.create!(conversation_params)
```

The conversation stores `chat_id` and (for Business Bots) `business_connection_id` in `additional_attributes` — these are needed later when sending replies.

**File:** `app/services/telegram/incoming_message_service.rb`

---

### Step 5: Build and save the Message

A `Message` record is created with `message_type: :incoming` (or `:outgoing` for business bot mirror messages):

| Telegram payload field | Chatwoot handling |
|---|---|
| `message.text` or `message.caption` | `content` field |
| `message.photo` (last/largest size) | Downloaded and stored as `image` attachment |
| `message.sticker.thumb` | Downloaded and stored as `image` attachment |
| `message.video` / `message.video_note` | Downloaded and stored as `video` attachment |
| `message.voice` / `message.audio` | Downloaded and stored as `audio` attachment |
| `message.document` | Downloaded and stored as `file` attachment |
| `message.location` / `message.venue` | Stored as `location` attachment with lat/lng coords |
| `message.contact` | Stored as `contact` attachment with name + phone |
| `callback_query.data` | Treated as text content (inline keyboard button press) |
| `message.reply_to_message.message_id` | Stored in `content_attributes.in_reply_to_external_id` |

For file attachments, the service calls `channel.get_telegram_file_path(file_id)` to get the download URL, then downloads the binary with the `Down` gem and stores it via Active Storage.

```ruby
@message = @conversation.messages.build(
  content: telegram_params_message_content,
  account_id: @inbox.account_id,
  inbox_id: @inbox.id,
  message_type: message_type,     # :incoming or :outgoing (business bot)
  sender: message_sender,         # @contact or nil (business bot)
  content_attributes: telegram_params_content_attributes,
  source_id: telegram_params_message_id.to_s
)
process_message_attachments if message_params?
@message.save!
```

**Files:** `app/services/telegram/incoming_message_service.rb`, `app/services/telegram/param_helpers.rb`

---

### Step 6: Real-time broadcast to agents

After `@message.save!`, Active Record callbacks fire the same broadcast pipeline used by all Chatwoot channels:

```
Message#after_create_commit
  └── dispatch_create_events
        └── Rails.configuration.dispatcher.dispatch('message.created', ...)
              ├── SyncDispatcher → ActionCableListener#message_created
              │     └── ActionCableBroadcastJob
              │           └── ActionCable.server.broadcast(agent_pubsub_token, {
              │                 event: 'message.created',
              │                 data: message.push_event_data
              │               })
              └── AsyncDispatcher → NotificationListener, WebhookListener,
                                    AutomationRuleListener, ...
```

The agent's browser is subscribed to their `pubsub_token` channel via Action Cable. The `message.created` event causes the Chatwoot Vue frontend to append the message to the conversation in real time — no page refresh needed.

---

## Part 2 — Outgoing Flow (Chatwoot Agent → Telegram User)

### Step 1: Agent sends a reply

The agent types a message in the Chatwoot UI and submits it. The frontend calls:

```
POST /api/v1/accounts/:account_id/conversations/:conversation_id/messages
Body: { content: "Hello! How can I help you?", message_type: "outgoing" }
```

**File:** `app/controllers/api/v1/accounts/conversations/messages_controller.rb`  
**Builder:** `app/builders/messages/message_builder.rb`

The builder creates the `Message` record with `message_type: :outgoing` and calls `@message.save!`.

---

### Step 2: Callbacks trigger the send job

The same `after_create_commit` callbacks fire as for incoming messages:

- **Action Cable** broadcasts the outgoing message to all agents watching the conversation (so other agents see the reply in real time).
- **`send_reply`** enqueues `SendReplyJob`:

```ruby
# app/models/message.rb
def send_reply
  SendReplyJob.perform_later(id)
end
```

---

### Step 3: Route to the Telegram service

`SendReplyJob` reads the channel type and dispatches to the correct service:

**File:** `app/jobs/send_reply_job.rb`
```ruby
CHANNEL_SERVICES = {
  'Channel::Telegram' => ::Telegram::SendOnTelegramService,
  # ... other channels
}.freeze

def perform(message_id)
  message = Message.find(message_id)
  channel_name = message.conversation.inbox.channel.class.to_s
  CHANNEL_SERVICES[channel_name].new(message: message).perform
end
```

---

### Step 4: Base service guards

`Telegram::SendOnTelegramService` inherits from `Base::SendOnChannelService`, which guards against:

- **Private (internal) notes** — not forwarded to any external platform.
- **Messages with a `source_id`** — these originated from Telegram itself (e.g. a Business Bot mirror message), forwarding them would create echo loops.

If both guards pass, `perform_reply` is called.

**File:** `app/services/base/send_on_channel_service.rb`

---

### Step 5: Dispatch to Telegram API

`Telegram::SendOnTelegramService#perform_reply` delegates to the channel model:

```ruby
# app/services/telegram/send_on_telegram_service.rb
def perform_reply
  message_id = channel.send_message_on_telegram(message)
  message.update!(source_id: message_id) if message_id.present?
end
```

`Channel::Telegram#send_message_on_telegram` decides what to call:

```ruby
def send_message_on_telegram(message)
  message_id = send_message(message) if message.outgoing_content.present?
  message_id = Telegram::SendAttachmentsService.new(message: message).perform if message.attachments.present?
  message_id
end
```

---

### Step 6: Build and send the text payload

For text messages, `send_message` calls `POST https://api.telegram.org/bot{token}/sendMessage`:

```ruby
def message_request(chat_id, text, reply_markup, reply_to_message_id, business_connection_id: nil)
  HTTParty.post("#{telegram_api_url}/sendMessage",
    body: {
      chat_id: chat_id,          # from conversation.additional_attributes['chat_id']
      text: text,                # agent reply content (Markdown → HTML converted)
      parse_mode: 'HTML',
      reply_markup: reply_markup,              # nil unless input_select
      reply_to_message_id: reply_to_message_id # nil unless agent is quoting a message
    }.merge(business_connection_body))
end
```

**Markdown → HTML conversion:** Chatwoot converts the agent's Markdown text to Telegram's supported HTML subset (using `CommonMarker`). Only these tags survive: `<b>`, `<i>`, `<u>`, `<s>`, `<a>`, `<code>`, `<pre>`, `<blockquote>`.

**`input_select` content type:** If the message contains quick-reply options, a `reply_markup` with `inline_keyboard` buttons is sent:

```ruby
def reply_markup(message)
  return unless message.content_type == 'input_select'

  {
    one_time_keyboard: true,
    inline_keyboard: message.content_attributes['items'].map do |item|
      [{ text: item['title'], callback_data: item['value'] }]
    end
  }.to_json
end
```

---

### Step 7: Send attachments

If the message has attachments, `Telegram::SendAttachmentsService` groups them by type and sends with the appropriate Telegram API endpoint:

| Attachment type | Telegram API | Method |
|---|---|---|
| `image` / `video` (single or grouped) | `sendMediaGroup` | Sends URL directly — Telegram fetches the file |
| `audio` (single or grouped) | `sendMediaGroup` | Sends URL directly |
| `file` / `document` | `sendDocument` | Multipart upload (Telegram only accepts PDF/ZIP via URL) |

Documents must be physically downloaded from Active Storage and re-uploaded to Telegram as multipart form data using `Faraday::Multipart`.

**File:** `app/services/telegram/send_attachments_service.rb`

---

### Step 8: Handle the Telegram API response

After the API call:

- **HTTP 200 (`ok: true`)** → the returned `message_id` is stored in `message.source_id`. This links the Chatwoot message record to the Telegram message for future edited-message lookups.
- **Non-200 / `ok: false`** → `channel.process_error` writes the Telegram error code and description to `message.external_error` and sets `message.status = :failed`.

```ruby
# app/models/channel/telegram.rb
def process_error(message, response)
  return unless response.parsed_response['ok'] == false

  message.external_error = "#{response.parsed_response['error_code']}, #{response.parsed_response['description']}"
  message.status = :failed
  message.save!
end
```

---

## Part 3 — Message Edit Flow (Telegram User edits a sent message)

Telegram allows users to edit sent messages within 48 hours. When this happens:

1. Telegram sends an `edited_message` (or `edited_business_message`) event to the webhook.
2. `TelegramEventsJob` routes it to `Telegram::UpdateMessageService`.
3. The service finds the existing `Message` record via `source_id` (the Telegram `message_id`).
4. It updates `message.content` with the new text or caption.

```ruby
# app/services/telegram/update_message_service.rb
def update_message
  @message.update!(content: edited_message[:text]) if edited_message[:text].present?
  @message.update!(content: edited_message[:caption]) if edited_message[:caption].present?
end
```

The `message.updated` event is dispatched and broadcast via Action Cable so agents see the edit in real time.

**File:** `app/services/telegram/update_message_service.rb`

---

## End-to-End Sequence Diagram

```
Telegram App      Telegram Platform       Chatwoot Backend              Agent Browser
    │                    │                       │                            │
    │──[user sends]──────►│                       │                            │
    │                    │──POST /webhooks/───────►│                            │
    │                    │   telegram/{token}      │                            │
    │                    │◄──200 OK────────────────│ (head :ok immediately)     │
    │                    │                         │                            │
    │                    │           TelegramEventsJob (async)                  │
    │                    │             ├─ lookup Channel::Telegram by token     │
    │                    │             ├─ check account active?                 │
    │                    │             ├─ route: new msg → IncomingMessageService
    │                    │             │   ├─ private_message? guard            │
    │                    │             │   ├─ find/create Contact (source_id)   │
    │                    │             │   ├─ fetch avatar (async job)          │
    │                    │             │   ├─ find/create Conversation          │
    │                    │             │   ├─ build Message + attachments       │
    │                    │             │   └─ message.save!                     │
    │                    │             └─ dispatch message.created              │
    │                    │                         │──ActionCableBroadcast─────►│
    │                    │                         │                     [message appears in UI]
    │                    │                         │                            │
    │                    │                         │◄──[agent types reply]──────│
    │                    │                         │                            │
    │                    │             MessageBuilder saves outgoing msg        │
    │                    │             └─ dispatch message.created              │
    │                    │                         │──ActionCableBroadcast─────►│ (reply shown)
    │                    │                         │                            │
    │                    │           SendReplyJob (async)                       │
    │                    │             └─ Telegram::SendOnTelegramService       │
    │                    │                  ├─ base guards (not note, no source_id)
    │                    │                  ├─ convert Markdown → HTML          │
    │                    │                  ├─ text? → sendMessage              │
    │                    │                  └─ attachments? → SendAttachmentsService
    │                    │──POST /sendMessage─────►(Telegram Bot API)           │
    │◄──[msg delivered]──│                         │                            │
    │                    │──200 ok + message_id────►│                            │
    │                    │                         │─ message.source_id saved   │
    │                    │                         │                            │
    │                    │   [user edits message]  │                            │
    │──[edit]────────────►│                         │                            │
    │                    │──POST edited_message────►│                            │
    │                    │                         │ TelegramEventsJob          │
    │                    │                         │  └─ UpdateMessageService   │
    │                    │                         │     └─ message.update!     │
    │                    │                         │──ActionCableBroadcast─────►│
    │                    │                         │                   [edit shown in UI]
```

---

## Key Files Reference

| Component | File |
|---|---|
| Webhook route | `config/routes.rb` |
| Webhook controller | `app/controllers/webhooks/telegram_controller.rb` |
| Job: channel lookup + routing | `app/jobs/webhooks/telegram_events_job.rb` |
| Incoming message parsing | `app/services/telegram/incoming_message_service.rb` |
| Payload param helpers | `app/services/telegram/param_helpers.rb` |
| Message edit handling | `app/services/telegram/update_message_service.rb` |
| Telegram channel model + Bot API client | `app/models/channel/telegram.rb` |
| Outgoing message routing | `app/jobs/send_reply_job.rb` |
| Outgoing message service | `app/services/telegram/send_on_telegram_service.rb` |
| Attachment sending | `app/services/telegram/send_attachments_service.rb` |
| Outgoing message base guard | `app/services/base/send_on_channel_service.rb` |
| Real-time broadcast | `app/listeners/action_cable_listener.rb` |
| Telegram inbox setup UI | `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Telegram.vue` |

---

## Key Differences vs. LINE Channel

| Aspect | LINE | Telegram |
|---|---|---|
| Webhook security | HMAC-SHA256 signature in `x-line-signature` header | Secret embedded in webhook URL (`/webhooks/telegram/{bot_token}`) |
| Channel lookup | `line_channel_id` in URL path | `bot_token` in URL path and `params[:bot_token]` |
| Signature validation step | Yes — explicit HMAC check in the job | No — security is URL-based |
| User profile fetch | Explicit call to LINE Get Profile API on every message | Avatar fetched once via `getUserProfilePhotos` (async, only if missing) |
| Conversation model | One conversation per user per inbox | One open conversation per user (or new if previous resolved, configurable via `lock_to_single_conversation`) |
| Message edit support | Not supported | Yes — `edited_message` events update the existing `Message` record |
| Quick-reply options | Flex Message with buttons | `inline_keyboard` via `reply_markup` |
| Attachment sending | LINE's Get Message Content API (binary download) | Telegram `getFile` API + URL or multipart upload depending on type |
| Business/partner chat | Not applicable | Telegram Business Bot mode — mirror messages become `:outgoing` type |
| Text formatting | Plain text | Markdown converted to Telegram HTML (`parse_mode: 'HTML'`) |

---

## Relevance for E-commerce Integration (Shopee / Lazada)

Telegram's implementation is notably simpler than LINE's because it uses URL-based security rather than HMAC headers, and it registers its own webhook automatically on inbox creation. The pattern is still the same as all Chatwoot channels:

1. **Incoming**: Platform POSTs to a webhook URL → background job validates + routes → `IncomingMessageService` parses → `Message` saved → Action Cable broadcasts.
2. **Outgoing**: Agent reply → `SendReplyJob` → platform-specific send service → platform API called → `message.source_id` updated.

For Shopee/Lazada, the key difference is that `Channel::Api` is used as the bridge instead of a native channel type, so the webhook registration step is handled by your adapter service rather than by Chatwoot itself.
