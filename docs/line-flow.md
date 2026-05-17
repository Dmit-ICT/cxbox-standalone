# LINE Channel Message Flow

This document describes the complete message lifecycle for the LINE channel in Chatwoot — from a user sending a message in the LINE app through to it appearing in the agent's inbox, and then the reverse path for agent replies back to the LINE user.

---

## Overview

```
LINE User ──────────────────────────────────────── LINE Agent (Chatwoot)
    │                                                        │
    │  [sends message]                                       │
    │──► LINE Platform ──► Webhook ──► Chatwoot Backend ──► │ (displayed in UI)
    │                                                        │
    │                                              [agent replies]
    │◄── LINE Platform ◄── LINE API ◄── Chatwoot Backend ◄──│
```

---

## Part 1 — Incoming Flow (LINE User → Chatwoot Agent)

### Step 1: LINE delivers the webhook

When a LINE user sends a message to a bot/channel, LINE's platform makes an HTTP `POST` request to the registered **webhook URL**:

```
POST /webhooks/line/:line_channel_id
Header: x-line-signature: <HMAC-SHA256 signature>
```

The `:line_channel_id` in the URL matches the `line_channel_id` stored in the `Channel::Line` record for that inbox.

**File:** `config/routes.rb`
```ruby
post 'webhooks/line/:line_channel_id', to: 'webhooks/line#process_payload'
```

---

### Step 2: Controller acknowledges immediately

The `Webhooks::LineController#process_payload` action does one thing — enqueue a background job and immediately respond `200 OK` to LINE. This prevents LINE from retrying due to a slow response.

**File:** `app/controllers/webhooks/line_controller.rb`
```ruby
def process_payload
  Webhooks::LineEventsJob.perform_later(
    params: params.to_unsafe_hash,
    signature: request.headers['x-line-signature'],
    post_body: request.raw_post
  )
  head :ok
end
```

---

### Step 3: Background job validates the payload

`Webhooks::LineEventsJob` performs two validations before processing:

1. **Channel lookup** — finds the `Channel::Line` record using `line_channel_id` from the route params. If no record exists, the job stops.
2. **Signature validation** — computes `HMAC-SHA256(raw_post_body, line_channel_secret)`, Base64-encodes it, and compares it to the `x-line-signature` header. This confirms the request genuinely came from LINE.

**File:** `app/jobs/webhooks/line_events_job.rb`
```ruby
def valid_post_body?(post_body, signature)
  hash = OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), @channel.line_channel_secret, post_body)
  Base64.strict_encode64(hash) == signature
end
```

After passing both checks, the job calls:
```ruby
Line::IncomingMessageService.new(inbox: @channel.inbox, params: @params['line'].with_indifferent_access).perform
```

---

### Step 4: Parse events and resolve the contact

`Line::IncomingMessageService#perform` iterates over `params[:events]`. For each event of type `"message"`:

#### 4a. Fetch LINE user profile

Calls LINE's **Get Profile** API to retrieve the sender's display name, avatar, and user ID:

```ruby
@line_contact_info = JSON.parse(inbox.channel.client.get_profile(event['source']['userId']).body)
# Returns: { "userId", "displayName", "pictureUrl", "statusMessage" }
```

#### 4b. Find or create the Chatwoot Contact

`ContactInboxWithContactBuilder` uses the LINE `userId` as `source_id` to find an existing `ContactInbox`, or creates a new `Contact` and `ContactInbox`:

```ruby
ContactInboxWithContactBuilder.new(
  source_id: @line_contact_info['userId'],
  inbox: inbox,
  contact_attributes: {
    name: displayName,
    avatar_url: pictureUrl,
    additional_attributes: { social_line_user_id: userId }
  }
).perform
```

#### 4c. Find or create the Conversation

```ruby
@conversation = @contact_inbox.conversations.first || Conversation.create!(conversation_params)
```

Each LINE user gets one conversation per inbox (no threading).

---

### Step 5: Build and save the Message

A `Message` record is created with `message_type: :incoming`:

| LINE event `message.type` | Handling |
|---|---|
| `text` | `content` = `event['message']['text']` |
| `sticker` | `content` = markdown image URL from sticker CDN |
| `image` / `video` / `audio` / `file` | Downloads binary via LINE's **Get Message Content** API, saves as `Attachment` |

```ruby
@message = @conversation.messages.build(
  content: message_content(event),
  content_type: message_content_type(event),  # 'text' or 'sticker'
  message_type: :incoming,
  sender: @contact,
  source_id: event['message']['id'].to_s,
  inbox_id: @inbox.id,
  account_id: @inbox.account_id
)
attach_files(event['message'])   # downloads media if applicable
@message.save!
```

---

### Step 6: Real-time broadcast to agents

After `@message.save!`, Active Record callbacks fire:

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
              └── AsyncDispatcher → NotificationListener, WebhookListener, AutomationRuleListener, ...
```

The agent's browser is subscribed to their `pubsub_token` via Action Cable. The `message.created` event causes the Chatwoot Vue frontend to append the new message to the conversation in real time — no page refresh needed.

---

## Part 2 — Outgoing Flow (Chatwoot Agent → LINE User)

### Step 1: Agent sends a reply

The agent types a message in the Chatwoot UI and submits it. The frontend calls:

```
POST /api/v1/accounts/:account_id/conversations/:conversation_id/messages
Body: { content: "Hello!", message_type: "outgoing" }
```

**File:** `app/controllers/api/v1/accounts/conversations/messages_controller.rb`  
**Builder:** `app/builders/messages/message_builder.rb`

The builder creates the `Message` record with `message_type: :outgoing` and calls `@message.save!`.

---

### Step 2: Callbacks trigger the send job

The same `after_create_commit` callbacks fire as for incoming messages:

- **Action Cable** broadcasts the new outgoing message back to all agents watching this conversation (so other agents see the reply in real time).
- **`send_reply`** enqueues `SendReplyJob`:

```ruby
# app/models/message.rb
def send_reply
  SendReplyJob.perform_later(id)
end
```

---

### Step 3: Route to the LINE service

`SendReplyJob` reads the inbox channel type and dispatches to the appropriate service:

**File:** `app/jobs/send_reply_job.rb`
```ruby
CHANNEL_SERVICES = {
  'Channel::Line' => ::Line::SendOnLineService,
  # ... other channels
}.freeze

def perform(message_id)
  message = Message.find(message_id)
  channel_name = message.conversation.inbox.channel.class.to_s
  CHANNEL_SERVICES[channel_name].new(message: message).perform
end
```

---

### Step 4: LINE service calls the LINE Push API

`Line::SendOnLineService` inherits from `Base::SendOnChannelService` which guards against:
- Private (internal note) messages
- Messages that already have a `source_id` (originated from LINE itself, avoids echo loops)

Then `perform_reply` sends to LINE:

**File:** `app/services/line/send_on_line_service.rb`
```ruby
def perform_reply
  response = channel.client.push_message(
    message.conversation.contact_inbox.source_id,  # LINE userId
    build_payload
  )
  # ...
end
```

`channel.client` is a `Line::Bot::Client` (from the `line-bot-api` gem) configured with the inbox's `line_channel_token`. The `push_message` method makes a `POST` to LINE's Messaging API:

```
POST https://api.line.me/v2/bot/message/push
Authorization: Bearer <line_channel_token>
{
  "to": "<LINE_userId>",
  "messages": [ ... ]
}
```

---

### Step 5: Build the message payload

The payload depends on the message content:

| Chatwoot message | LINE payload type |
|---|---|
| Text only | `{ type: 'text', text: '...' }` |
| Text + image/video attachment | Array: `[text_message, { type: 'image', originalContentUrl: '...', previewImageUrl: '...' }]` |
| Image/video only | Array of media objects |
| `input_select` content type | [Flex Message](https://developers.line.biz/en/reference/messaging-api/#flex-message) with buttons for each option |

**Example text payload:**
```json
{
  "to": "U4af4980629...",
  "messages": [
    { "type": "text", "text": "Hello! How can I help you?" }
  ]
}
```

**Example Flex Message (for quick-reply options):**
```json
{
  "to": "U4af4980629...",
  "messages": [{
    "type": "flex",
    "altText": "Please choose an option",
    "contents": {
      "type": "bubble",
      "body": {
        "type": "box",
        "layout": "vertical",
        "contents": [
          { "type": "text", "text": "Please choose an option", "wrap": true },
          { "type": "button", "style": "link", "action": { "type": "message", "label": "Option A", "text": "Option A" } }
        ]
      }
    }
  }]
}
```

---

### Step 6: Handle the LINE API response

After the `push_message` call:

- **HTTP 200** → `Messages::StatusUpdateService` marks the message as `delivered`. This triggers `message.updated` dispatch → `ActionCableListener#message_updated` → broadcasts the status change to agents in real time (the message tick turns green/delivered).
- **Non-200** → Status set to `failed` and the LINE error detail (from `error['message']` + `error['details']`) is stored in `external_error`.

---

## End-to-End Sequence Diagram

```
LINE App         LINE Platform        Chatwoot Backend              Agent Browser
   │                   │                     │                            │
   │──[user sends]────►│                     │                            │
   │                   │──POST /webhooks/────►│                            │
   │                   │   line/:id          │                            │
   │                   │◄──200 OK────────────│ (head :ok immediately)     │
   │                   │                     │                            │
   │                   │            LineEventsJob (async)                 │
   │                   │              ├─ validate signature               │
   │                   │              ├─ GET /profile/:userId ────────────►(LINE API)
   │                   │              ├─ find/create Contact              │
   │                   │              ├─ find/create Conversation         │
   │                   │              ├─ build & save Message             │
   │                   │              └─ dispatch message.created         │
   │                   │                     │──ActionCableBroadcast─────►│
   │                   │                     │                     [message appears in UI]
   │                   │                     │                            │
   │                   │                     │◄──[agent types reply]──────│
   │                   │                     │                            │
   │                   │             MessageBuilder saves outgoing msg    │
   │                   │              └─ dispatch message.created         │
   │                   │                     │──ActionCableBroadcast─────►│ (reply shown)
   │                   │                     │                            │
   │                   │             SendReplyJob (async)                 │
   │                   │              └─ Line::SendOnLineService          │
   │                   │──POST /v2/bot/◄──────│                            │
   │                   │   message/push       │                            │
   │◄──[msg delivered]─│                     │                            │
   │                   │──200 OK─────────────►│                            │
   │                   │                     │──status: delivered ───────►│
```

---

## Key Files Reference

| Component | File |
|---|---|
| Webhook route | `config/routes.rb` |
| Webhook controller | `app/controllers/webhooks/line_controller.rb` |
| Signature validation + dispatch | `app/jobs/webhooks/line_events_job.rb` |
| Incoming message parsing | `app/services/line/incoming_message_service.rb` |
| LINE channel model / SDK client | `app/models/channel/line.rb` |
| Outgoing message routing | `app/jobs/send_reply_job.rb` |
| LINE push API call | `app/services/line/send_on_line_service.rb` |
| Outgoing message base guard | `app/services/base/send_on_channel_service.rb` |
| Real-time broadcast | `app/listeners/action_cable_listener.rb` |
| Message status update | `app/services/messages/status_update_service.rb` |
| LINE inbox setup UI | `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Line.vue` |

---

## Relevance for E-commerce Integration (Shopee / Lazada)

Understanding this LINE flow is useful as a template for adding Shopee or Lazada integrations, because the pattern is consistent across all channels in Chatwoot:

1. **Incoming**: Register a webhook URL in the e-commerce platform → validate the signature → call `Line::IncomingMessageService`-equivalent → save `Message` → broadcast via Action Cable.
2. **Outgoing**: Agent sends reply → `SendReplyJob` dispatches to your new `Shopee::SendOnShopeeService` or `Lazada::SendOnLazadaService` → call the platform's send API → update message status.

The key extension points are:
- A new `Channel::Shopee` / `Channel::Lazada` model (credentials + SDK client)
- A new webhook controller + route + events job
- An `IncomingMessageService` to parse platform-specific payloads into Chatwoot `Message` records
- A `SendOnShopeeService` / `SendOnLazadaService` inheriting `Base::SendOnChannelService`
- Registration in `SendReplyJob::CHANNEL_SERVICES`
