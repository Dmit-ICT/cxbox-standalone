# CXBox Standalone — Project Overview

## Purpose

An **open-source omnichannel customer support platform** — a self-hosted alternative to Intercom/Zendesk. Supports live chat, email, Facebook, Instagram, Twitter, WhatsApp, Telegram, Line, SMS, and AI-powered agent assistance. Designed for teams who want full data control.

---

## Tech Stack

| Layer | Technology |
|---|---|
| **Backend** | Ruby on Rails 7.1 (Ruby 3.4.4) |
| **Frontend** | Vue.js 3 + Vite 5 + Tailwind CSS |
| **State Management** | Pinia 3 (new) + Vuex 4 (legacy) |
| **Database** | PostgreSQL 16 with pgvector extension |
| **Cache / Queue** | Redis (Alpine) |
| **Background Jobs** | Sidekiq 7 + Sidekiq-Cron |
| **Auth** | Devise + DeviseTokenAuth + 2FA |
| **Authorization** | Pundit policies |
| **AI / LLM** | OpenAI, ruby_llm, pgvector embeddings |
| **Storage** | Local / AWS S3 / Azure / GCS |
| **Email Testing** | MailHog |
| **Search** | pg_search, OpenSearch (optional) |
| **APM** | Sentry, Datadog, New Relic (optional) |
| **Package Manager** | pnpm 10.x |

---

## How to Run Locally

### Option A — Native (Recommended for development)

Prerequisites: Ruby 3.4.4, pnpm 10.x, PostgreSQL 16, Redis

```bash
bundle install
pnpm install
cp .env.example .env
bundle exec rails db:setup
pnpm dev        # or: overmind start -f Procfile.dev
```

This starts 3 processes: Rails (port 3000), Sidekiq, Vite (port 3036).

### Option B — Docker Compose

```bash
docker-compose -f docker-compose.yaml up
```

---

## Local Development Step-by-Step

1. Install Ruby 3.4.4 via `rbenv`:
   ```bash
   rbenv install $(cat .ruby-version)
   eval "$(rbenv init -)"
   ```
2. Install Ruby gems:
   ```bash
   bundle install
   ```
3. Install JS dependencies:
   ```bash
   pnpm install
   ```
4. Set up environment:
   ```bash
   cp .env.example .env
   # Set SECRET_KEY_BASE in .env:
   bundle exec rails secret
   ```
5. Set up database:
   ```bash
   bundle exec rails db:create db:migrate db:seed
   ```
6. Start all processes:
   ```bash
   pnpm dev
   ```
7. Open http://localhost:3000

### Seed Richer Test Data (optional)
```bash
bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.first)"
```

---

## Docker Containers

### `docker-compose.yaml` — Full Development (6 containers)

| Container | Image | Port |
|---|---|---|
| `rails` | chatwoot-rails:development | 3000 |
| `sidekiq` | chatwoot-rails:development | — |
| `vite` | chatwoot-vite:development | 3036 |
| `postgres` | pgvector/pgvector:pg16 | 5432 |
| `redis` | redis:alpine | 6379 |
| `mailhog` | mailhog/mailhog | 1025, 8025 |

### `docker-compose.dev.yaml` — Custom Dev (infra only, 3 containers)

postgres, redis, mailhog — with custom volume at `/Users/bomdmit/DockerVolumes/cxbox-standalone`

### `docker-compose.production-custom.yaml` — DemeterICT Production (5 containers)

| Container | Notes |
|---|---|
| `rails` | Image: `demeterict/cxbox-standalone:baseline` |
| `sidekiq` | Same baseline image |
| `postgres` | pgvector/pg16, database: `standalone_db` |
| `redis` | Alpine with password auth |
| `storage` | Volume: `storage_data` |

### `docker-compose.production.yaml` — Official Production (5 containers)

rails, sidekiq, postgres, redis, storage volume — bound to 127.0.0.1

### `docker-compose.test.yaml` — CI Testing (3 containers)

postgres, redis, mailhog (no Rails/Sidekiq — tests run in CI)

---

## Architecture

```
Vue.js 3 (Vite, port 3036)
        │
Rails 7.1 API + ActionCable (WebSocket, port 3000)
        │
        ├── PostgreSQL 16 + pgvector  ← main data store + AI embeddings
        ├── Redis                     ← job queue + pub/sub + sessions
        └── Sidekiq                   ← async jobs (email, webhooks, AI, reports)
```

### Rails App Structure

```
app/
├── controllers/   → API endpoint handlers
├── models/        → 55+ domain models (Account, Conversation, Contact, Channel…)
├── services/      → Business logic layer
├── jobs/          → Sidekiq background jobs
├── channels/      → ActionCable WebSocket handlers
├── policies/      → Pundit authorization policies
├── listeners/     → Event-driven pub/sub (Wisper)
├── builders/      → Complex object construction
├── mailers/       → Email notification handlers
└── javascript/    → Vue.js 3 frontend components
```

### Key Design Patterns

- **Pub/Sub**: Wisper gem for loose coupling between components
- **Service Layer**: Business logic encapsulated in `app/services/`
- **Pundit Policies**: Fine-grained authorization per resource
- **Sidekiq Jobs**: All async processing (delivery, reports, AI)
- **Enterprise Overlay**: `enterprise/` directory extends OSS features without forking

### Data Flow

1. **Real-time conversations**: WebSocket (ActionCable) ↔ Rails ↔ PostgreSQL, Redis pub/sub for multi-instance
2. **Message processing**: Incoming webhook → Rails → Sidekiq → PostgreSQL → WebSocket broadcast
3. **Channel integrations**: Channel-specific webhooks → unified message format → outbound API calls
4. **AI features**: Text embeddings → pgvector → vector similarity search → LLM API
5. **Reporting**: Aggregation queries on PostgreSQL, optional OpenSearch for advanced search

---

## Supported Channels

Facebook, Instagram, Twitter, WhatsApp, Telegram, Line, Twilio SMS, Email (ActionMailbox), Live Chat (web widget)

## Deployment Targets

- Docker Compose (dev, test, production)
- Heroku (via `Procfile`)
- DigitalOcean / Kubernetes (via Helm)
- Self-hosted on any VM with Docker
- GitHub Codespaces (devcontainer support)
