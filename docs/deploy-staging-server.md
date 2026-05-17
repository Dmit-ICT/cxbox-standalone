# Deploy Staging Server on Google Compute Engine (Docker Compose)

This guide walks through deploying `cxbox-standalone` (Chatwoot fork) as a **staging** server on a single Google Compute Engine (GCE) VM using `docker compose` and the existing `docker-compose.production-custom.yaml`.

It covers: provisioning the VM, installing Docker, getting the code onto the VM, configuring `.env`, building/running the stack, initializing the database, and putting HTTPS in front with Caddy.

---

## 0. Architecture Overview

The staging stack runs four containers on one VM:

| Service  | Image                                     | Port (host) | Purpose                    |
|----------|-------------------------------------------|-------------|----------------------------|
| rails    | `demeterict/cxbox-standalone:baseline`    | `3000`      | Rails web server           |
| sidekiq  | `demeterict/cxbox-standalone:baseline`    | —           | Background jobs            |
| postgres | `pgvector/pgvector:pg16`                  | `127.0.0.1:5432` | Database               |
| redis    | `redis:alpine`                            | `127.0.0.1:6379` | Cache / queue broker   |

A Caddy reverse proxy container terminates TLS and forwards `:443` → `rails:3000`.

Data is persisted in Docker named volumes: `storage_data`, `postgres_data`, `redis_data`.

---

## 1. Prerequisites

On your local machine:

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- A GCP project selected (`gcloud config set project <PROJECT_ID>`)
- Billing enabled on that project
- A domain name you control (for HTTPS), e.g. `staging.example.com`

---

## 2. Provision the GCE VM

### 2.1 Create the instance

Use `e2-standard-2` (2 vCPU, 8 GB RAM) as a sensible staging baseline. Ubuntu 24.04 LTS for a clean Docker setup.

```bash
gcloud compute instances create cxbox-staging \
  --zone=asia-southeast1-a \
  --machine-type=e2-standard-2 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-balanced \
  --tags=http-server,https-server
```

> Pick the zone closest to your users. `--tags=http-server,https-server` enables the default firewall rules for ports 80/443.

### 2.2 Reserve a static external IP (recommended)

```bash
gcloud compute addresses create cxbox-staging-ip --region=asia-southeast1

gcloud compute addresses describe cxbox-staging-ip \
  --region=asia-southeast1 --format='value(address)'
```

Assign it to the instance:

```bash
# Detach the ephemeral IP
gcloud compute instances delete-access-config cxbox-staging \
  --zone=asia-southeast1-a --access-config-name="external-nat"

# Attach the static IP (replace STATIC_IP with the output above)
gcloud compute instances add-access-config cxbox-staging \
  --zone=asia-southeast1-a \
  --access-config-name="external-nat" \
  --address=STATIC_IP
```

### 2.3 Point DNS to the VM

Create an `A` record for your chosen staging domain pointing to the static IP:

```
staging.example.com   A   <STATIC_IP>
```

Wait for DNS to propagate before the HTTPS step.

### 2.4 SSH into the VM

```bash
gcloud compute ssh cxbox-staging --zone=asia-southeast1-a
```

All subsequent commands run **on the VM** unless noted.

---

## 3. Install Docker on the VM

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker "$USER"
```

Log out and back in so the group change takes effect:

```bash
exit
gcloud compute ssh cxbox-staging --zone=asia-southeast1-a
```

Verify:

```bash
docker --version
docker compose version
```

---

## 4. Get the code onto the VM

Clone the repository. Use a deploy key or a personal access token if the repo is private.

```bash
cd ~
git clone https://github.com/<your-org>/cxbox-standalone.git
cd cxbox-standalone
```

> If the repo is private, prefer adding an SSH deploy key to the VM (`ssh-keygen -t ed25519 -C "cxbox-staging"`, then add `~/.ssh/id_ed25519.pub` to GitHub as a read-only deploy key) and clone via `git@github.com:...`.

---

## 5. Configure `.env` for staging

Copy the example and edit:

```bash
cp .env.example .env
```

Generate secrets:

```bash
# SECRET_KEY_BASE (alphanumeric only)
openssl rand -hex 64

# REDIS_PASSWORD
openssl rand -hex 32

# Active Record Encryption keys (run once the containers exist, see Step 7)
```

Edit `.env` and set at minimum:

```env
# --- Core ---
SECRET_KEY_BASE=<paste-openssl-rand-hex-64>
RAILS_ENV=production
NODE_ENV=production
INSTALLATION_ENV=docker

# --- URL ---
FRONTEND_URL=https://staging.example.com
FORCE_SSL=true
ENABLE_ACCOUNT_SIGNUP=false

# --- Postgres (must match docker-compose.production-custom.yaml) ---
POSTGRES_HOST=postgres
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=Password1234!
POSTGRES_DATABASE=standalone_db

# --- Redis ---
REDIS_URL=redis://:<redis-password>@redis:6379
REDIS_PASSWORD=<redis-password>

# --- Mail (configure real SMTP or leave blank for staging) ---
MAILER_SENDER_EMAIL=Staging <staging@example.com>
SMTP_ADDRESS=
SMTP_PORT=587

# --- Logs ---
RAILS_LOG_TO_STDOUT=true
LOG_LEVEL=info
```

> **Important**: `POSTGRES_PASSWORD` in `.env` must match the password hardcoded in `docker-compose.production-custom.yaml`. If you change one, change the other. For real staging, replace `Password1234!` with a generated secret in both places.

### 5.1 Lock down `.env`

```bash
chmod 600 .env
```

---

## 6. Build and start the stack

From the project root on the VM:

```bash
docker compose -f docker-compose.production-custom.yaml build
docker compose -f docker-compose.production-custom.yaml up -d
```

Watch the logs until Rails is up:

```bash
docker compose -f docker-compose.production-custom.yaml logs -f rails
```

Check container status:

```bash
docker compose -f docker-compose.production-custom.yaml ps
```

---

## 7. Initialize the database

On first boot the Rails entrypoint usually handles schema loading, but run these to be explicit and idempotent:

```bash
docker compose -f docker-compose.production-custom.yaml exec rails \
  bundle exec rails db:chatwoot_prepare
```

> `db:chatwoot_prepare` creates the DB if missing, loads schema, and runs seeds. If that task is not available in your branch, fall back to `db:create db:schema:load db:seed`.

### 7.1 Generate Active Record Encryption keys (required for MFA)

```bash
docker compose -f docker-compose.production-custom.yaml exec rails \
  bundle exec rails db:encryption:init
```

Copy the three `ACTIVE_RECORD_ENCRYPTION_*` values it prints into `.env`, then restart:

```bash
docker compose -f docker-compose.production-custom.yaml up -d
```

### 7.2 Create the super admin user

```bash
docker compose -f docker-compose.production-custom.yaml exec rails \
  bundle exec rails runner "SuperAdmin.create!(email: 'admin@example.com', password: 'ChangeMeNow!1')"
```

Super admin console: `https://staging.example.com/super_admin`.

---

## 8. Put HTTPS in front (Caddy reverse proxy)

Rails listens on `:3000` inside the Docker network. Expose it publicly via Caddy (automatic Let's Encrypt).

Create `~/caddy/Caddyfile` on the VM:

```bash
mkdir -p ~/caddy
cat > ~/caddy/Caddyfile <<'EOF'
staging.example.com {
  encode zstd gzip
  reverse_proxy rails:3000
}
EOF
```

Create `~/caddy/docker-compose.yaml`:

```yaml
version: '3'

services:
  caddy:
    image: caddy:2-alpine
    restart: always
    ports:
      - '80:80'
      - '443:443'
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - cxbox

networks:
  cxbox:
    external: true
    name: cxbox-standalone_default

volumes:
  caddy_data:
  caddy_config:
```

> The `name:` under `networks.cxbox` must match the network Docker Compose creates for the app. Verify it with `docker network ls`; it is usually `<project-dir>_default`, e.g. `cxbox-standalone_default`.

Start Caddy:

```bash
cd ~/caddy
docker compose up -d
docker compose logs -f caddy
```

Caddy will obtain a Let's Encrypt certificate automatically. Visit `https://staging.example.com`.

### 8.1 Stop exposing Rails directly

In `docker-compose.production-custom.yaml`, the `rails` service publishes `3000:3000`. Since Caddy now proxies to it on the internal Docker network, change it to bind to localhost only (or remove it entirely):

```yaml
  rails:
    # ...
    ports:
      - '127.0.0.1:3000:3000'
```

Then:

```bash
cd ~/cxbox-standalone
docker compose -f docker-compose.production-custom.yaml up -d
```

---

## 9. GCP firewall check

The `http-server` / `https-server` tags applied in Step 2 open ports 80 and 443. Confirm:

```bash
gcloud compute firewall-rules list --filter="name~'default-allow-http'"
```

You do **not** need to expose `3000`, `5432`, or `6379` to the public internet.

---

## 10. Common operations

### Tail logs

```bash
cd ~/cxbox-standalone
docker compose -f docker-compose.production-custom.yaml logs -f rails
docker compose -f docker-compose.production-custom.yaml logs -f sidekiq
```

### Rails console

```bash
docker compose -f docker-compose.production-custom.yaml exec rails \
  bundle exec rails c
```

### Run a migration

```bash
docker compose -f docker-compose.production-custom.yaml exec rails \
  bundle exec rails db:migrate
```

### Restart a single service

```bash
docker compose -f docker-compose.production-custom.yaml restart rails
```

### Rebuild after code changes

```bash
cd ~/cxbox-standalone
git pull
docker compose -f docker-compose.production-custom.yaml build rails
docker compose -f docker-compose.production-custom.yaml up -d
docker compose -f docker-compose.production-custom.yaml exec rails \
  bundle exec rails db:migrate
```

---

## 11. Backups (minimum viable)

Daily Postgres dump to the VM disk:

```bash
mkdir -p ~/backups
cat > ~/backups/pg_backup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/cxbox-standalone"
STAMP=$(date +%Y%m%d_%H%M%S)
docker compose -f docker-compose.production-custom.yaml exec -T postgres \
  pg_dump -U postgres standalone_db | gzip > "$HOME/backups/standalone_db_$STAMP.sql.gz"
find "$HOME/backups" -name 'standalone_db_*.sql.gz' -mtime +7 -delete
EOF
chmod +x ~/backups/pg_backup.sh
```

Schedule with cron:

```bash
( crontab -l 2>/dev/null; echo "0 3 * * * $HOME/backups/pg_backup.sh" ) | crontab -
```

For real durability, sync `~/backups` to a GCS bucket with `gsutil rsync` or the `gcloud storage` CLI.

---

## 12. Tearing it all down

```bash
# App stack (keep data)
cd ~/cxbox-standalone
docker compose -f docker-compose.production-custom.yaml down

# App stack + data volumes (DESTRUCTIVE)
docker compose -f docker-compose.production-custom.yaml down -v

# Caddy
cd ~/caddy
docker compose down

# Delete the VM
gcloud compute instances delete cxbox-staging --zone=asia-southeast1-a

# Release the static IP
gcloud compute addresses delete cxbox-staging-ip --region=asia-southeast1
```

---

## Troubleshooting

- **Rails container keeps restarting** — check `docker compose ... logs rails`. Most common causes: `SECRET_KEY_BASE` missing, Postgres not ready yet (wait 30s and retry), or `POSTGRES_PASSWORD` mismatch between `.env` and the compose file.
- **`FATAL: password authentication failed for user "postgres"`** — `.env` and `docker-compose.production-custom.yaml` disagree on `POSTGRES_PASSWORD`. Either align both, or wipe the Postgres volume (`docker compose ... down -v`) and restart.
- **Redis auth errors** — `REDIS_URL` must include the password, e.g. `redis://:<pw>@redis:6379`, and `REDIS_PASSWORD` must match.
- **Caddy can't reach `rails:3000`** — the Caddy container isn't on the app's Docker network. Run `docker network ls` and update the `external.name` in `~/caddy/docker-compose.yaml`.
- **Assets missing / 404** — the image is built with `RAILS_SERVE_STATIC_FILES=true`. If you see stale assets after a deploy, rebuild the `rails` image (`docker compose ... build rails`).
- **Out of memory during build** — `e2-standard-2` is tight for asset precompile. Temporarily resize to `e2-standard-4`, build, then resize back.
