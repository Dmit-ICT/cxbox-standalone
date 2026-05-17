# Local Development Setup

Run infrastructure services as Docker containers and the Rails app natively.

## Prerequisites

- Docker Desktop running
- Ruby (via `rbenv`) — version from `.ruby-version`
- Node.js + pnpm
- Bundler

---

## Step 1 — Copy and configure environment

```bash
cp .env.example .env
```

Generate a Redis password and set it in `.env`:

```bash
openssl rand -hex 32
```

Edit `.env` with the values matching the containers below:

```env
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=Password1234!

REDIS_URL=redis://:<generated-redis-password>@localhost:6379
REDIS_PASSWORD=<generated-redis-password>

SMTP_ADDRESS=localhost
SMTP_PORT=1025
```

> Replace `<generated-redis-password>` with the output from the `openssl` command above. Use the same value for both `REDIS_URL` and `REDIS_PASSWORD`.

---

## Step 2 — Start infrastructure containers

The file is located at the project root: `cxbox-standalone/docker-compose.dev.yaml`

```bash
docker compose -f docker-compose.dev.yaml up -d
```

This starts:

| Service  | Port(s)       | Notes                          |
|----------|---------------|--------------------------------|
| Postgres | `5432`        | pgvector/pg16, data persisted at `/Users/bomdmit/DockerVolumes/cxbox-standalone` |
| Redis    | `6379`        | Password from `REDIS_PASSWORD` in `.env` |
| Mailhog  | `1025` (SMTP) / `8025` (UI) | Web UI at http://localhost:8025 |

Verify containers are up:

```bash
docker compose -f docker-compose.dev.yaml ps
```

---

## Step 3 — Install dependencies

```bash
brew install overmind
eval "$(rbenv init -)"
bundle install
pnpm install
```

---

## Step 4 — Set up the database

```bash
bundle exec rails db:create db:schema:load db:seed
```

---

## Step 5 — Run the app natively

```bash
pnpm dev
```

Or with Overmind:

```bash
overmind start -f Procfile.dev
```

This starts:

| Process | Command                              | Default Port |
|---------|--------------------------------------|--------------|
| backend | `bin/rails s -p 3000`                | 3000         |
| worker  | `bundle exec sidekiq -C config/sidekiq.yml` | —       |
| vite    | `bin/vite dev`                       | 3036         |

App is available at: http://localhost:3000

---

## Stopping

```bash
# Stop app processes
# Ctrl+C in the terminal running pnpm dev / overmind

# Stop containers (keep data)
docker compose -f docker-compose.dev.yaml stop

# Stop and remove containers (data still persisted in volumes)
docker compose -f docker-compose.dev.yaml down
```
