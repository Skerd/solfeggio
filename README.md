# Solfeggio — Arpeggio Deployment Toolkit

Solfeggio orchestrates a full Docker-based deployment of the **Arpeggio** platform. It clones application source code, generates infrastructure cluster configurations, wires environment variables and TLS certificates, builds container images, and brings the stack online behind an Nginx gateway.

The Arpeggio platform consists of three packages:

| Package | Role |
|---------|------|
| **Armonia** | Shared TypeScript types, schema definitions, and Zod validators |
| **Maestro** | API server — persistence, business logic, HTTP routes, Kafka consumers, cron jobs, WebSocket |
| **Sinfonia** | Client SPA — admin panel, view engine, module contribution system |

Solfeggio does not contain application logic. It prepares a `deploy/<instance>/` workspace with the selected modules and infrastructure, then builds and runs everything via Docker Compose.

## Instances

An **instance** is one named deployment: its own module set, Maestro containers, Sinfonia clients and data. Several instances (for example `ecommerce` and `propertymanagement`) run side by side on one Docker host and share the infrastructure clusters and the Nginx gateway.

| Shared by all instances | Separate per instance |
|-------------------------|-----------------------|
| MongoDB cluster | MongoDB database (and its user) |
| Kafka brokers | Kafka topics and consumer groups, prefixed `<instance>-` |
| Redis cluster | Redis logical database (`REDIS_DATABASE`, 0-15) |
| ClamAV, Ollama, Prometheus | Maestro containers `maestro<Role>-<instance>` |
| Nginx gateway (one container) | Sinfonia containers `frontend-<instance>-<appId>`, gateway domains or port |

`./deploy.sh` picks the instance from the module list: entering a module set that an instance already deploys selects that instance, so re-running it with `core,eCommerce` or `core,propertyManagement` updates the matching one. `./systemUp.sh <instance>` then rebuilds and restarts only that instance's containers.

Per-instance state:

- `apps/maestro/instances/<instance>.env` — the instance's Maestro env. Created from `apps/maestro/.env` the first time; edit it and re-run `./systemUp.sh <instance>` to apply. Review the values that must differ between instances (`CLIENT_NAME`, `EMAIL_*`, `TELEGRAM_TOKEN`, `STRIPE_*`, OAuth redirect URLs, JWT/session secrets).
- `deploy/<instance>/` — cloned sources, build manifests and compose files.

Gateway rules for more than one instance:

- **Host mode** instances may share the gateway port; each domain's `/api/` and `/ws/` reach the Maestro of the instance that owns the domain.
- A **path mode** instance needs a gateway port of its own (e.g. one instance on `80`, another on `8080`).

A Kafka topic or consumer group is only prefixed when its `KAFKA_TOPIC_*` / `KAFKA_CONSUMER_GROUP_*` key exists in the instance env. Add new keys to `apps/maestro/.env` so instances do not fall back to a shared default name.

**Upgrading a stack deployed before instances existed:** deploy it once as an instance with the same modules and keep the suggested database (the cluster's existing one). `./systemUp.sh` asks before removing the old un-instanced containers (`maestroApi`, `frontend-core`, …); data in MongoDB is untouched.

## Prerequisites

- **Docker** with Compose v2 (`docker compose`) or standalone `docker-compose`
- **Git** — used to clone Armonia, Maestro, Sinfonia, and module repositories
- **Bash** — deployment scripts require a POSIX shell

## Quick start

```bash
# 1. Prepare deployment sources and infrastructure configuration
./deploy.sh

# 2. Build images and start the instance deploy.sh just prepared
./systemUp.sh
```

Repeat both steps for every instance.

After `systemUp.sh` completes, entry points depend on gateway mode:

**Path mode** (default) — all clients share the Nginx gateway port (default `80`):

- **First selected app** (usually `core`): `http://localhost:80/`
- **Additional apps**: `http://localhost:80/<appId>App/` (e.g. `http://localhost:80/publicApp/`)

Example after selecting `core,public`:

- **core:** `http://localhost/`
- **public:** `http://localhost/publicApp/`

**Host mode** — each client at `/` on its own domain (same gateway port), e.g.
`dyeus@dyeus.al,core@panel.pronix.al,public@pronix.al` → `http://dyeus.al/`, `http://panel.pronix.al/`, `http://pronix.al/`.
Point DNS at the gateway; TLS is not generated here (Cloudflare / front proxy / extend `gateway.conf`).

To tear down generated artifacts and start fresh:

```bash
./cleanDeploy.sh
```

## Deployment workflow

### 1. `./deploy.sh` — configure and prepare sources

Interactive wizard that:

1. Prompts for **modules** to deploy (comma-separated, e.g. `finance,eCommerce`; `core` is always included)
2. Prompts for the **instance** name (default: the instance that already deploys those modules, else the last module in lowercase) and creates its Maestro env on first use
3. Sets the shared **Docker internal network** name (default: `arpeggio_internal_network`)
4. Clones or updates **Armonia**, **Maestro**, and **Sinfonia** core repos plus per-module repos from GitHub
5. Prompts for **Sinfonia client apps** to deploy:
   - Path mode: comma-separated ids under `src/modules/*/apps/` (e.g. `core,public`)
   - Host mode: `id@domain` mounts (e.g. `dyeus@dyeus.al,core@panel.pronix.al,public@pronix.al`). `www.` is added automatically. A shop catch-all is `public@*.arpeggio.al` (no www pair).
6. Generates `deploy/<instance>/scripts/modules.manifest.json` and `sinfonia-apps.env`
7. Configures optional and required **infrastructure clusters** (generated once, reused by later instances) and assigns the instance its MongoDB database, Redis database and Kafka prefix
8. Copies the instance's Maestro env into `deploy/<instance>/maestro/.env`

**Required infrastructure** (always configured):

- **MongoDB** — sharded cluster with TLS; primary application database
- **Nginx gateway** — public entry point(s) for selected Sinfonia clients, `/api/`, and `/ws/`

**Optional infrastructure** (prompted during deploy):

- **Kafka** — async emails, login history, API metrics, distributed cron, property-management notifications
- **Redis** — rate limiting, cron locking, WebSocket coordination, health/stats caching
- **ClamAV** — real malware scanning for file uploads (falls back to mock scanner when disabled)

Each cluster is generated by an interactive `generate-cluster.sh` script under `clusters/<name>/`. Generated compose files, certificates, and scripts are gitignored and recreated on each deploy.

### 2. `./systemUp.sh` — build and start

Works on one instance: the one named on the command line, or the one `./deploy.sh` prepared last. It validates the prepared `deploy/<instance>/` folder, then:

1. Ensures the shared Docker network exists
2. Builds the instance's **Maestro** and **Sinfonia** Docker images from `apps/*/Dockerfile` (Sinfonia clients build in parallel; npm/native layers cache unless `package.json` changes)
3. Generates `deploy/<instance>/docker-compose.servers.yml` and `docker-compose.frontend.yml`
4. Starts infrastructure clusters (MongoDB → Redis → Kafka → ClamAV → Prometheus); already running clusters are left as they are
5. Creates the instance's MongoDB database and user if they do not exist
6. Starts the instance's Maestro services and Sinfonia client containers
7. Regenerates the Nginx gateway for this instance plus every other instance that is running, and starts it last

**Maestro containers** (one image per instance, different commands):

| Container | Command | Purpose |
|-----------|---------|---------|
| `maestroApi-<instance>` | `npm run api` | REST API |
| `maestroKafka-<instance>` | `npm run kafka` | Kafka consumers |
| `maestroWebsocket-<instance>` | `npm run websocket` | WebSocket server |
| `maestroCron-<instance>` | `npm run cron` | Scheduled jobs |
| `maestroAssistant-<instance>` | `npm run assistant` | AI-channel responder |
| `maestroTelegram-<instance>` | `npm run telegram` | Telegram bot long-poll + linking |

**Frontend containers** (one per selected Sinfonia client app):

| Container | Purpose |
|-----------|---------|
| `frontend-<instance>-<appId>` | Built SPA for `src/modules/<module>/apps/<appId>` (internal port 80) |

Example: selecting `core,public` for instance `propertymanagement` yields `frontend-propertymanagement-core` and `frontend-propertymanagement-public`.

Usage:

```bash
./systemUp.sh                            # instance prepared last by deploy.sh, full build
./systemUp.sh ecommerce                  # a named instance
./systemUp.sh ecommerce --skip-maestro   # SPA-only: reuse the existing Maestro image
./systemUp.sh ecommerce --skip-frontend  # API-only: reuse existing Sinfonia images
./systemUp.sh ecommerce --no-cache       # force a clean rebuild (slow)
```

### 3. `./cleanDeploy.sh` — reset

Removes the `deploy/` folder (all instances) and generated cluster artifacts (compose files, certs, scripts). Preserves cluster `.env` files, `generate-cluster.sh` scripts, `apps/maestro/.env` and the instance envs in `apps/maestro/instances/`. Running containers are not stopped; re-run `./deploy.sh` and `./systemUp.sh` for every instance afterwards.

## Directory layout

```
solfeggio/
├── deploy.sh              # Interactive deployment preparation
├── systemUp.sh            # Build images and start the stack
├── cleanDeploy.sh         # Remove generated deploy and cluster artifacts
├── apps/
│   ├── deploy.dockerignore
│   ├── maestro/
│   │   ├── Dockerfile     # Maestro image (Node 22, canvas, ffmpeg, opencv.js)
│   │   ├── .env           # Maestro env template (gitignored; seed for new instances)
│   │   └── instances/     # <instance>.env — Maestro env per instance (gitignored; edited by deploy.sh)
│   └── sinfonia/
│       └── Dockerfile     # Multi-stage Sinfonia build → Nginx static serve (`VITE_SINFONIA_APP`)
├── lib/
│   ├── instances.sh             # Shared instance naming/path helpers
│   └── sinfonia-client-apps.sh  # Shared client-app selection/parsing helpers
├── clusters/
│   ├── kafka/             # KRaft Kafka cluster (SASL_SSL)
│   ├── redis/             # Redis with Sentinel
│   ├── mongo/             # Sharded MongoDB with TLS
│   ├── clamv/             # ClamAV antivirus
│   ├── nginx/             # Reverse proxy / load balancer gateway
│   └── prometheus/        # Metrics (optional)
└── deploy/                # Generated at deploy time (gitignored)
    └── <instance>/
        ├── armonia/
        ├── maestro/
        ├── sinfonia/
        ├── scripts/
        ├── docker-compose.servers.yml
        └── docker-compose.frontend.yml
```

## Nginx gateway routes

Each instance is published in either **path** or **host** mode on its gateway port (default `80`). The tables below show one instance; with several, every instance gets its own set of routes and `/api/` and `/ws/` always reach that instance's own Maestro (`maestroApi-<instance>`, `maestroWebsocket-<instance>`).

### Path mode

The first selected Sinfonia client is at `/`; every additional client is at `/<appId>App/`. Each SPA is built at `/`.

| Path | Upstream | Purpose |
|------|----------|---------|
| `/` | `frontend-<instance>-<rootApp>` | Default/root Sinfonia client (usually `core`) |
| `/<appId>App/` | `frontend-<instance>-<appId>` | Additional Sinfonia clients (e.g. `public` → `/publicApp/`) |
| `/assets/` | root client | Root SPA static assets |
| `/api/` | `maestroApi-<instance>` | Maestro REST API |
| `/api/auxiliary/media/` | `maestroApi-<instance>` | Media uploads/downloads |
| `/ws/` | `maestroWebsocket-<instance>` | WebSocket server |

### Host mode

Each client is a separate nginx `server_name` vhost at `/`. `/api/` and `/ws/` are available on every domain of the instance.

| Domain | Path | Upstream |
|--------|------|----------|
| `dyeus.al` | `/` | `frontend-<instance>-dyeus` |
| `panel.pronix.al` | `/` | `frontend-<instance>-core` |
| `pronix.al` (+ `www.pronix.al`) | `/` | `frontend-<instance>-public` |
| *(each domain)* | `/api/`, `/ws/` | The instance's Maestro |

Example selection: `dyeus@dyeus.al,core@panel.pronix.al,public@pronix.al`

`www.<domain>` is paired automatically (`dyeus.al` also serves `www.dyeus.al`). Extra aliases still use `|` (`public@pronix.al|shop.pronix.al`). A leading `*.zone` catch-all (`public@*.arpeggio.al`) is a valid host and does not get a www pair; nginx exact names (`panel.arpeggio.al`) still win over that wildcard. Unmatched Host headers return 404 instead of the first client's SPA.

Client selection and gateway port are stored per instance in `deploy/<instance>/scripts/sinfonia-apps.env`; the gateway generator reads that file for every instance.

See [clusters/nginx/README.md](clusters/nginx/README.md) for details after running `./deploy.sh`.

## Infrastructure clusters

Each cluster directory contains:

- `generate-cluster.sh` — interactive generator (preserved in git)
- `.env` / `.env.test` — configuration templates (`.env` is gitignored after first deploy)
- Generated artifacts — `docker-compose.yml`, certs, scripts (gitignored)

| Cluster | Default | Notes |
|---------|---------|-------|
| MongoDB | Required | Sharded cluster; TLS certs copied to `deploy/<instance>/maestro/secrets/certificates/mongo/` |
| Nginx | Required | Public entry point; configured with upstream replica counts |
| Kafka | Optional | KRaft mode, SASL_SSL; see [clusters/kafka/README.md](clusters/kafka/README.md) |
| Redis | Optional | Master/replica with Sentinel |
| ClamAV | Optional | Mock scanner used when disabled |
| Prometheus | Optional | Started by `systemUp.sh` when generated |

## Environment configuration

Each instance's Maestro environment is managed through `apps/maestro/instances/<instance>.env` (seeded from `apps/maestro/.env`). During `./deploy.sh`, connection settings are written automatically based on cluster choices:

- `MONGODB_*` — router host, credentials, TLS cert paths, and the instance's database (asked once, then kept)
- `KAFKA_*` — brokers, SASL credentials, CA path, and the `<instance>-` prefix on topics and consumer groups (when Kafka is enabled)
- `REDIS_*` — root nodes, auth, and the instance's logical database (when Redis is enabled)
- `CLAMAV_*` — host/port (when ClamAV is enabled)
- `CLIENT_HOST` — public origin of the **core/panel** SPA (auth emails, Stripe). Derived from the selected `core` client's domain in host mode (`https://panel.pronix.al`). Never `localhost` or the Docker-internal gateway. Left unchanged when no public origin exists (path mode without a real domain).
- `SINFONIA_CLIENT_URLS` — per-app map written from the same selection, e.g. `core=https://panel.pronix.al,public=https://pronix.al,dyeus=https://dyeus.al`. Maestro uses this so shop/public/panel mail links hit the matching SPA. `CLIENT_NAME` is left as-is.
- `SHOP_ROOT_DOMAIN` — zone for per-company shops (`{slug}.arpeggio.al`). Set this on the instance env (`arpeggio.al`). Company create still succeeds when it is empty; the shop provision step stays failed until it is set.
- `ENABLED_MODULES` — comma-separated module list matching the deploy selection

The finalized env is copied to `deploy/<instance>/maestro/.env` for container runtime, by `./deploy.sh` and again by every `./systemUp.sh`.

## Managing running services

**Maestro servers:**

```bash
cd deploy/<instance>
docker compose -p servers-<instance> -f docker-compose.servers.yml ps
docker compose -p servers-<instance> -f docker-compose.servers.yml logs -f
docker compose -p servers-<instance> -f docker-compose.servers.yml down
```

**Frontend:**

```bash
cd deploy/<instance>
docker compose -p frontend-<instance> -f docker-compose.frontend.yml ps
docker compose -p frontend-<instance> -f docker-compose.frontend.yml logs -f
docker compose -p frontend-<instance> -f docker-compose.frontend.yml down
```

After stopping an instance, run `./systemUp.sh` for another instance to drop it from the gateway.

**Infrastructure** (example for MongoDB):

```bash
cd clusters/mongo
docker compose ps
docker compose logs -f
```

## Image build context

Dockerfiles under `apps/` expect the instance's **`deploy/<instance>/` folder** as build context (not `apps/` itself). Both images require **armonia** alongside the application package:

```bash
# Maestro
docker build -f apps/maestro/Dockerfile -t arpeggio-maestro-<instance>:latest deploy/<instance>/

# Core client
docker build -f apps/sinfonia/Dockerfile \
  --build-arg VITE_SINFONIA_APP=core \
  -t arpeggio-frontend-<instance>-core:latest deploy/<instance>/

# Public client (own hostname in host mode)
docker build -f apps/sinfonia/Dockerfile \
  --build-arg VITE_SINFONIA_APP=public \
  -t arpeggio-frontend-<instance>-public:latest deploy/<instance>/
```

`systemUp.sh` copies `apps/deploy.dockerignore` to `deploy/<instance>/.dockerignore` so git metadata and `node_modules` are not sent as build context. Vite `ARG`s are applied after `npm install`, so core/public/dyeus share dependency layers and only the Vite step differs.

`systemUp.sh` builds whichever clients were selected in `./deploy.sh`. Override naming with:

- `ARPEGGIO_MAESTRO_IMAGE` (default: `arpeggio-maestro-<instance>:latest`)
- `ARPEGGIO_FRONTEND_IMAGE_PREFIX` (default: `arpeggio-frontend` → images `arpeggio-frontend-<instance>-<appId>:latest`)

## Module repositories

Core repos are cloned from GitHub during `./deploy.sh`:

- `armonia_core`, `maestro_core`, `sinfonia_core`
- Per-module repos: `armonia_<module>`, `maestro_<module>`, `sinfonia_<module>`

Branch selection is prompted per core and per module. All default to `main`.

Available modules depend on what exists in the Skerd GitHub organization (e.g. `eCommerce`, `eCommerceMarketplace`, `propertyManagement`).

## Related documentation

Application packages are documented separately in their own repositories:

- **Maestro** — API server, CRUD router factory, database conventions, server entry points
- **Sinfonia** — panel shell, module contributions, view engine, routing
- **Armonia** — shared schema definitions and validators

Cluster-specific setup details are generated into each cluster's README after `./deploy.sh` runs (Kafka and Nginx).
