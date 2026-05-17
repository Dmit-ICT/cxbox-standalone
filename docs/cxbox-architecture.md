# CXBox Platform — Architecture Design

> **Project goal:** An omni-channel customer support SaaS (like Zendesk) that integrates
> e-commerce chat (Shopee, Lazada, TikTok Shop) and social chat (LINE, Facebook, Instagram,
> WhatsApp) from a single interface, built on top of [Chatwoot](https://www.chatwoot.com)
> with minimal changes to the original source code.

---

## Table of Contents

1. [What Chatwoot Provides Out of the Box](#1-what-chatwoot-provides-out-of-the-box)
2. [Core Strategy — Channel::Api as the Bridge](#2-core-strategy--channelapi-as-the-bridge)
3. [Full Platform Architecture](#3-full-platform-architecture)
4. [Component Details](#4-component-details)
   - [Chatwoot Core](#41-chatwoot-core--zero-changes-for-mvp)
   - [E-Commerce Adapter Service](#42-e-commerce-adapter-service)
   - [Message Queue — Redis Streams](#43-message-queue--redis-streams)
   - [Per-Platform Adapter Pattern](#44-per-platform-adapter-pattern)
5. [Data Flow](#5-data-flow)
   - [Inbound: Buyer → Agent](#51-inbound-flow-buyer--agent)
   - [Outbound: Agent → Buyer](#52-outbound-flow-agent--buyer)
6. [Adapter Service Database Schema](#6-adapter-service-database-schema)
7. [Phased Rollout Plan](#7-phased-rollout-plan)
8. [Technology Stack](#8-technology-stack)
9. [Key Architectural Decisions](#9-key-architectural-decisions)

---

## 1. What Chatwoot Provides Out of the Box

The following channels and features are **available with zero code changes** — just configuration:

| Feature / Channel | Status |
|---|---|
| LINE | Native (`Channel::Line`) |
| Facebook Messenger | Native (`Channel::FacebookPage`) |
| Instagram | Native (`Channel::Instagram`) |
| WhatsApp | Native (`Channel::Whatsapp`) |
| TikTok (social messaging) | Native (`Channel::Tiktok`) |
| Telegram | Native (`Channel::Telegram`) |
| Email | Native (`Channel::Email`) |
| SMS (Twilio / plain) | Native (`Channel::TwilioSms`, `Channel::Sms`) |
| Multi-tenant (accounts) | Built-in |
| Agent assignment & routing | Built-in |
| Internal queue (Sidekiq/Redis) | Built-in |
| Webhook events to external URLs | Built-in (`WebhookListener`) |
| REST API for conversations & messages | Built-in (`/api/v1/accounts/...`) |

**What requires custom work:**
Shopee, Lazada, and TikTok Shop (e-commerce seller chat) — these are not social platforms
and have different, seller-oriented APIs.

---

## 2. Core Strategy — `Channel::Api` as the Bridge

Chatwoot ships a generic `Channel::Api` channel type that is the **designed-in extension
point** for connecting external platforms without touching core source code.

### How it works

- Each `Channel::Api` inbox has a `webhook_url` field.
- Chatwoot's `WebhookListener` automatically fires a `POST` to that URL on every event
  (`message_created`, `conversation_created`, `conversation_status_changed`, etc.).
- This means: **every time an agent replies, your microservice is notified automatically**.

```
Channel::Api (inbox)
  └── webhook_url = https://adapter.cxbox.io/webhooks/chatwoot
```

You post incoming messages *to* Chatwoot via its REST API.
Chatwoot posts agent replies *back to you* via the `webhook_url`.

**Result: zero Chatwoot source changes needed for the entire e-commerce integration.**

---

## 3. Full Platform Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            CXBOX PLATFORM                                │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                    Reverse Proxy / Nginx                            │  │
│  │         (SSL termination, domain routing, rate limiting)            │  │
│  └──────────────────────┬──────────────────────┬───────────────────────┘  │
│                         │                      │                         │
│              ┌──────────▼──────────┐  ┌────────▼──────────────────────┐  │
│              │   CHATWOOT CORE      │  │   E-COMMERCE ADAPTER SERVICE   │  │
│              │   (unchanged)        │  │   (new microservice)           │  │
│              │                      │  │                                │  │
│              │  Native channels:    │  │  ┌──────────────────────────┐  │  │
│              │  • LINE              │  │  │  Inbound Queue            │  │  │
│              │  • Facebook          │◄─┼──┤  (Redis Streams)          │  │  │
│              │  • Instagram         │  │  └───────────┬──────────────┘  │  │
│              │  • WhatsApp          │  │              │                  │  │
│              │  • TikTok social     │  │  ┌───────────▼──────────────┐  │  │
│              │  • Telegram          │  │  │  Platform Adapters        │  │  │
│              │                      │  │  │  • ShopeeAdapter          │  │  │
│              │  Channel::Api        │  │  │  • LazadaAdapter          │  │  │
│              │  (one inbox per      │──►  │  • TikTokShopAdapter      │  │  │
│              │   tenant's shop)     │  │  └───────────┬──────────────┘  │  │
│              │                      │  │              │                  │  │
│              │  webhook_url ────────┼──►  ┌───────────▼──────────────┐  │  │
│              │  fires on replies    │  │  │  Outbound Queue           │  │  │
│              │                      │  │  │  (Redis Streams)          │  │  │
│              │  Sidekiq / Redis     │  │  └───────────┬──────────────┘  │  │
│              │  (internal jobs)     │  │              │                  │  │
│              └──────────┬──────────┘  │  ┌───────────▼──────────────┐  │  │
│                         │             │  │  Adapter Database          │  │  │
│              ┌──────────▼──────────┐  │  │  • platform_credentials   │  │  │
│              │   PostgreSQL DB      │  │  │  • conversation_mappings  │  │  │
│              │   (Chatwoot DB)      │  │  │  • message_mappings       │  │  │
│              └─────────────────────┘  │  └──────────────────────────┘  │  │
│                                       └───────────────────────────────-┘  │
└──────────────────────────────────────────────────────────────────────────┘

External platforms:
  Shopee / Lazada / TikTok Shop ──► E-Commerce Adapter (webhooks or polling)
  LINE / Facebook / Instagram / WhatsApp ──► Chatwoot Core (native webhooks)
```

---

## 4. Component Details

### 4.1 Chatwoot Core — Zero Changes for MVP

Configure, don't code:

- Enable social channels in the Chatwoot admin panel (provide platform app credentials).
- For each tenant's e-commerce shop, create a `Channel::Api` inbox with `webhook_url`
  pointing to `https://adapter.cxbox.io/webhooks/chatwoot`.
- Name the inbox clearly, e.g. `"Shopee — BrandName Store"`.
- Use account-level webhooks for any global event monitoring.

### 4.2 E-Commerce Adapter Service

This is the **core microservice you build**. It has four responsibilities:

| Responsibility | Description |
|---|---|
| **Inbound receiver** | Receives webhooks (or runs pollers) from Shopee/Lazada/TikTok Shop |
| **Chatwoot API client** | Creates conversations and messages in Chatwoot via REST API |
| **Outbound receiver** | Receives Chatwoot's `message_created` webhook when an agent replies |
| **Platform sender** | Sends agent replies back to the buyer on the original platform |

### 4.3 Message Queue — Redis Streams

Reuses the **existing Redis** instance (already running for Sidekiq). No extra infrastructure.

| Stream key | Purpose |
|---|---|
| `cxbox:inbound:shopee` | Incoming buyer messages from Shopee |
| `cxbox:inbound:lazada` | Incoming buyer messages from Lazada |
| `cxbox:outbound:shopee` | Agent replies to send back to Shopee |
| `cxbox:outbound:lazada` | Agent replies to send back to Lazada |

Benefits over simple polling or direct API calls:
- **At-least-once delivery** with consumer groups — no lost messages.
- **Message ordering** per conversation.
- **Replay** capability for debugging.
- Decouples slow platform APIs from fast Chatwoot API calls.
- Absorbs traffic spikes gracefully.

### 4.4 Per-Platform Adapter Pattern

Each platform adapter implements a common interface so queue workers are platform-agnostic:

```ruby
# Conceptual interface (implement in adapter service)
class ShopeeAdapter
  def fetch_new_messages(credentials)       # → Array[NormalizedMessage]
  def send_message(credentials, thread_id, content)
  def normalize_incoming(raw_payload)       # → NormalizedMessage
  def register_webhook(credentials, callback_url)
end

# Shared normalized message format (maps directly to Chatwoot API shape)
NormalizedMessage = Struct.new(
  :platform_thread_id,   # buyer ID, order ID, or chat session ID
  :platform_sender_id,
  :sender_name,
  :content,
  :content_type,         # text, image, file, etc.
  :attachments,
  :sent_at
)
```

---

## 5. Data Flow

### 5.1 Inbound Flow: Buyer → Agent

```
1. Buyer sends a message on Shopee/Lazada
        │
        ▼
2. Platform webhook fires (or polling job runs)
        │
        ▼
3. Adapter Service receives raw payload
        │
        ▼
4. Normalize to NormalizedMessage format
        │
        ▼
5. Publish to Redis Stream: cxbox:inbound:{platform}
        │
        ▼
6. Stream consumer worker picks up message
        │
        ├─► Look up tenant's Chatwoot account_id + inbox_id
        │     (from platform_credentials table using shop_id)
        │
        ├─► Find or create Contact in Chatwoot
        │     POST /api/v1/accounts/{id}/contacts
        │
        ├─► Find or create Conversation in Chatwoot
        │     POST /api/v1/accounts/{id}/conversations
        │     (check conversation_mappings table first)
        │
        ├─► Save conversation mapping
        │     chatwoot_conversation_id ↔ platform_thread_id
        │
        └─► Create incoming message in Chatwoot
              POST /api/v1/accounts/{id}/conversations/{id}/messages
                   { message_type: "incoming", content: "..." }
        │
        ▼
7. Chatwoot shows the message to agents in the UI ✓
```

### 5.2 Outbound Flow: Agent → Buyer

```
1. Agent types a reply in Chatwoot and sends it
        │
        ▼
2. Chatwoot fires webhook to Channel::Api webhook_url
   POST https://adapter.cxbox.io/webhooks/chatwoot
   {
     "event": "message_created",
     "message_type": "outgoing",
     "conversation": { "id": 123 },
     "content": "Hello! How can I help you?"
   }
        │
        ▼
3. Adapter's webhook endpoint receives the POST
        │
        ▼
4. Look up conversation_mappings: Chatwoot conv ID → platform_thread_id + platform
        │
        ▼
5. Publish to Redis Stream: cxbox:outbound:{platform}
        │
        ▼
6. Outbound stream worker picks up message
        │
        ├─► Look up platform credentials for this tenant
        │
        └─► Call platform API to send reply
              e.g. Shopee Seller Chat API: send_message(thread_id, content)
        │
        ▼
7. Buyer receives the reply on Shopee/Lazada ✓
```

---

## 6. Adapter Service Database Schema

This is a **separate database** from Chatwoot — never share the same DB.

```sql
-- Tenant's per-platform credentials and inbox mapping
CREATE TABLE platform_credentials (
  id                   BIGSERIAL PRIMARY KEY,
  chatwoot_account_id  BIGINT       NOT NULL,   -- Chatwoot account (tenant)
  chatwoot_inbox_id    BIGINT       NOT NULL,   -- Channel::Api inbox ID
  platform             VARCHAR(50)  NOT NULL,   -- 'shopee', 'lazada', 'tiktok_shop'
  shop_id              VARCHAR(255),            -- platform's shop/seller ID
  access_token         TEXT,                    -- OAuth access token (encrypted)
  refresh_token        TEXT,                    -- OAuth refresh token (encrypted)
  token_expires_at     TIMESTAMP,
  extra_config         JSONB,                   -- platform-specific settings
  created_at           TIMESTAMP    NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMP    NOT NULL DEFAULT NOW(),
  UNIQUE (chatwoot_account_id, platform, shop_id)
);

-- Maps Chatwoot conversation IDs to platform chat thread IDs
CREATE TABLE conversation_mappings (
  id                          BIGSERIAL PRIMARY KEY,
  chatwoot_account_id         BIGINT      NOT NULL,
  chatwoot_conversation_id    BIGINT      NOT NULL UNIQUE,
  platform                    VARCHAR(50) NOT NULL,
  platform_thread_id          VARCHAR(255) NOT NULL,  -- buyer user ID or chat session ID
  created_at                  TIMESTAMP   NOT NULL DEFAULT NOW()
);

-- Optional: track individual message IDs for read receipts / status updates
CREATE TABLE message_mappings (
  id                       BIGSERIAL PRIMARY KEY,
  chatwoot_message_id      BIGINT      NOT NULL UNIQUE,
  platform_message_id      VARCHAR(255) NOT NULL,
  platform                 VARCHAR(50) NOT NULL,
  created_at               TIMESTAMP   NOT NULL DEFAULT NOW()
);
```

---

## 7. Phased Rollout Plan

### Phase 1 — MVP (Chatwoot unchanged)

- [ ] Deploy Chatwoot as-is; configure native social channels (LINE, FB, WA, IG, TikTok)
- [ ] Build E-Commerce Adapter Service for **Shopee only**
- [ ] Use `Channel::Api` as bridge — **zero Chatwoot source changes**
- [ ] Use Redis Streams for both inbound and outbound queues
- [ ] Manual tenant onboarding (admin creates `Channel::Api` inboxes by hand)
- [ ] Validate end-to-end: buyer message → Chatwoot UI → agent reply → buyer

### Phase 2 — Multi-Tenant Self-Service

- [ ] Build a **tenant registration portal** (separate app or Chatwoot-mounted engine)
- [ ] Automate inbox creation via Chatwoot REST API when a tenant registers a shop
- [ ] Add OAuth flows for Shopee/Lazada token management
- [ ] Add Lazada adapter
- [ ] Add TikTok Shop adapter

### Phase 3 — Native Channel Types (Optional Polish)

- [ ] Add `Channel::Shopee` and `Channel::Lazada` models to Chatwoot source
  (following the existing channel pattern in `app/models/channel/`)
- [ ] This unlocks platform-specific icons, actions, and UI labels in Chatwoot
- [ ] Add entries to `SendReplyJob::CHANNEL_SERVICES`
- [ ] This is the **only phase** that requires touching Chatwoot source code

### Phase 4 — Scale & Reliability

- [ ] Move Redis Streams to a dedicated Redis instance (separate from Sidekiq)
- [ ] Add dead-letter queues for failed message delivery
- [ ] Add monitoring / alerting (Datadog, Sentry, etc.)
- [ ] Add token auto-refresh for platform OAuth credentials
- [ ] Implement webhook signature verification for all inbound webhooks

---

## 8. Technology Stack

| Component | Recommendation | Reason |
|---|---|---|
| Chatwoot Core | Ruby on Rails (unchanged) | Existing codebase |
| E-Commerce Adapter | Ruby (Rails API or Sinatra) **or** Node.js | Ruby keeps same language; Node.js excels at I/O-heavy adapter work |
| Message Queue | Redis Streams | Reuses existing Redis — no extra infrastructure |
| Adapter Database | PostgreSQL (separate DB from Chatwoot) | Isolation; independent deployability |
| Reverse Proxy | Nginx | Route `/webhooks/shopee` → adapter, all else → Chatwoot |
| Containerization | Docker Compose (dev) → Kubernetes (prod) | Scale adapters independently from Chatwoot |
| Secrets / Token storage | Rails credentials or HashiCorp Vault | Never store raw OAuth tokens in DB |

---

## 9. Key Architectural Decisions

| Decision | Choice | Reason |
|---|---|---|
| Social channels (LINE, FB, WA, IG, TikTok) | Use Chatwoot native | Already built and battle-tested |
| E-commerce channels (Shopee, Lazada) | `Channel::Api` + Adapter microservice | Zero Chatwoot source changes for MVP |
| Chatwoot ↔ Adapter communication | REST API (inbound) + `webhook_url` (outbound) | Both are built-in to Chatwoot |
| Queue technology | Redis Streams | Reuses existing Redis; no new infrastructure |
| Tenancy model | Chatwoot accounts = tenants | Already multi-tenant by design |
| Source code changes to Chatwoot | **Zero for Phase 1 & 2** | Avoids merge conflicts on upstream updates |
| E-commerce adapter database | Separate from Chatwoot DB | Independent deployment and scaling |
| Platform credential storage | Adapter DB only (encrypted) | Never expose tokens through Chatwoot |

---

## References

- Chatwoot docs: <https://www.chatwoot.com/docs>
- Chatwoot Channel::Api: `app/models/channel/api.rb`
- Chatwoot WebhookListener: `app/listeners/webhook_listener.rb`
- Chatwoot SendReplyJob: `app/jobs/send_reply_job.rb`
- Existing channel pattern example: `app/models/channel/line.rb`, `app/controllers/webhooks/line_controller.rb`, `app/services/line/`
- Shopee Open Platform: <https://open.shopee.com>
- Lazada Open Platform: <https://open.lazada.com>
