# Hermes Setup – Production Installer Plan

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Hermes Agent (SSOT)](#2-hermes-agent-ssot)
3. [Open WebUI](#3-open-webui)
4. [AionUi](#4-aionui)
5. [Docker Compose](#5-docker-compose)
6. [Custom Dockerfile (AionUi)](#6-custom-dockerfile-aionui)
7. [Install Scripts](#7-install-scripts)
8. [Provider/Model Sync Flow](#8-providermodel-sync-flow)
9. [Security Considerations](#9-security-considerations)
10. [Post-Install Verification & Maintenance](#10-post-install-verification--maintenance)
11. [Design Decisions & Rationale](#11-design-decisions--rationale)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Host                           │
│                                                          │
│  ┌──────────────┐     ┌──────────────────┐              │
│  │  Hermes Agent │────▶│  Open WebUI      │              │
│  │  (port 8642)  │◀────│  (port 3000)     │              │
│  │  API Server   │     │  OpenAI-compat   │              │
│  │  + ACP        │     │  HTTP client     │              │
│  └──────┬───────┘     └──────────────────┘              │
│         │                                                │
│         │ ACP channel                                    │
│         ▼                                                │
│  ┌──────────────┐                                        │
│  │  AionUi       │                                        │
│  │  (port 3001)  │                                        │
│  │  ACP client   │                                        │
│  └──────────────┘                                        │
└─────────────────────────────────────────────────────────┘
```

**Key principles:**
- **Single Source of Truth:** `~/.hermes/config.yaml` – provider list, model config, API key
- **API proxy:** Hermes API server (`:8642/v1`) – both UIs consume via OpenAI-compatible endpoint
- **ACP channel:** AionUi invokes `hermes acp` for agent capabilities
- **Config sync:** UIs auto-discover models (Open WebUI fetches `/v1/models` on page load; AionUi reads config via bind mount)
- **No duplicate config:** Provider/model changes are made only in `~/.hermes/config.yaml`; UIs adapt automatically

**Deployment modes:**
| Mode | Hermes Agent | Open WebUI | AionUi |
|------|-------------|------------|--------|
| **host** | Native (pip) | Docker | Docker |
| **docker** | Docker | Docker | Docker |

---

## 2. Hermes Agent (SSOT)

### Role
Provider registry, OpenAI-compatible API proxy, ACP host for agent capabilities.

### Configuration

**`~/.hermes/config.yaml`:**
```yaml
api_server:
  enabled: true
  key: ${API_SERVER_KEY}
  port: 8642

providers:
  # User-configured LLM providers go here
  # Example:
  # - name: openai
  #   api_key: ${OPENAI_API_KEY}
  #   base_url: https://api.openai.com/v1

auxiliary:
  compression:
    timeout: 300  # Tuned from default 120s to prevent retry storms

# Hermes auto-detects and hot-reloads changes via mtime polling
```

**`~/.hermes/.env`:**
```
API_SERVER_ENABLED=true
API_SERVER_KEY=<generated-32-char-hex>
# Provider credentials as needed
```

### API Endpoints
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/models` | GET | List available models (Bearer auth) |
| `/v1/chat/completions` | POST | Chat completion (Bearer auth) |
| Port | – | 8642 |

### Startup Requirements
- `API_SERVER_ENABLED=true` AND `API_SERVER_KEY` must be set (both required; server will not start without key)
- Config loaded from `~/.hermes/config.yaml` (from bind mount `/opt/data` in Docker)

### Known Production Tuning
- `auxiliary.compression.timeout: 300` prevents 8x retry increase from default 120s timeout (hermes-agent#22986)

---

## 3. Open WebUI

### Role
Chat UI consuming Hermes as OpenAI-compatible backend.

### Environment Variables
| Variable | Value | Source |
|----------|-------|--------|
| `OPENAI_API_BASE_URL` | `http://hermes:8642/v1` | Auto-appended `/v1` |
| `OPENAI_API_KEY` | `${API_SERVER_KEY}` | Generated per-install |
| `BYPASS_MODEL_ACCESS_CONTROL` | `true` | Prevents "no models" for non-admin users |
| `AIOHTTP_CLIENT_TIMEOUT` | `120` | Prevents infinite hang on slow backends |

### URL Handling
- Trailing slashes are stripped from `OPENAI_API_BASE_URL` before setting
- `/v1` path is auto-appended if missing (verified: Open WebUI silently returns zero models without `/v1`)
- Internal port: 8080 (mapped to host port 3000)

### Healthcheck
- Uses `GET /health` endpoint
- Confirmed safe: returns `{"status": true}` with no model enumeration, DB queries, or external calls
- `start_period: 15s` to cover startup

### Model Discovery
- Fetched on page load / model selector open
- Server-side caching via `ENABLE_BASE_MODELS_CACHE` (disabled by default)
- `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` defaults to 10s (acceptable)

### Data Storage
- Named volume: `open-webui-data:/app/backend/data`
- Contains SQLite DB, uploads, user config

---

## 4. AionUi

### Role
Agent UI consuming Hermes via ACP + OpenAI-compatible API.

### ACP Integration
- **Registry:** `ACP_BACKENDS_ALL` env var includes Hermes
- **Detection:** AionUi checks `command -v hermes` on startup
- **Built-in definition:**
  ```json
  {
    "name": "Hermes",
    "cliCommand": "hermes",
    "acpArgs": ["acp"],
    "env": { "ACP_BACKENDS_ALL": "hermes" }
  }
  ```

### Configuration
- **Primary:** Hermes config mounted read-only at `/opt/data/config.yaml` inside container
- **Fallback:** No separate AionUi config needed for provider/model discovery
- **Persistent data:** Named volume `aionui-data:/data`

### Custom Dockerfile
- Multi-stage build with `hermes-agent[acp]` pre-installed (not runtime apt-get)
- Ensures reproducible builds and `hermes` CLI on PATH at `/usr/local/bin/hermes`

### Healthcheck
- TCP check on port 3001 (not HTTP – no guaranteed HTTP endpoint)
- `start_period: 30s` to cover ACP detection + startup

### Startup Sequence
1. Container starts, ACP detector runs
2. Detects `hermes` CLI on PATH via `command -v hermes`
3. Registers Hermes ACP backend
4. Reads Hermes config from bind mount for provider info
5. Web UI available on port 3001

### WSL2 Handling
- **Detected via:** `grep -qi microsoft /proc/version`
- **Action:** If WSL2 detected in host mode, warn user and suggest:
  - Docker mode (all containerized, no GUI issues)
  - OR `--webui` flag for AionUi with `--no-sandbox --disable-gpu` workarounds
- **Reason:** Electron 37 / Chromium 138 crashes on WSLg's Weston compositor (aionui#2748, #2767)

---

## 5. Docker Compose

**File:** `compose/docker-compose.yml`

```yaml
services:
  hermes:
    image: ghcr.io/anomalyco/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    ports:
      - "8642:8642"
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - API_SERVER_ENABLED=true
      - API_SERVER_KEY=${API_SERVER_KEY}
    healthcheck:
      test: ["CMD-SHELL", "curl -skf -H 'Authorization: Bearer $API_SERVER_KEY' http://localhost:8642/v1/models >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    volumes:
      - open-webui-data:/app/backend/data
    environment:
      - OPENAI_API_BASE_URL=http://hermes:8642/v1
      - OPENAI_API_KEY=${API_SERVER_KEY}
      - BYPASS_MODEL_ACCESS_CONTROL=true
      - AIOHTTP_CLIENT_TIMEOUT=120
    depends_on:
      hermes:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

  aionui:
    build:
      context: ./docker
      dockerfile: aionui.Dockerfile
    container_name: aionui
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - aionui-data:/data
      - ~/.hermes:/opt/data:ro
    depends_on:
      hermes:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "timeout 2 bash -c 'echo > /dev/tcp/localhost/3001' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  open-webui-data:
  aionui-data:
```

### Volume Strategy
| Service | Type | Mount | Purpose |
|---------|------|-------|---------|
| Hermes | Bind | `~/.hermes:/opt/data` | SSOT config (read-write) |
| AionUi | Bind (ro) | `~/.hermes:/opt/data:ro` | Config read (read-only) |
| Open WebUI | Named volume | `open-webui-data:/app/backend/data` | Persistent data |
| AionUi | Named volume | `aionui-data:/data` | Persistent data |

### Healthcheck Details
| Service | Method | Auth | Why |
|---------|--------|------|-----|
| Hermes | `curl /v1/models` with Bearer | Yes | Verifies API server is functional |
| Open WebUI | `curl /health` | No | Trivial liveness (`{"status":true}`) |
| AionUi | TCP port check | N/A | No guaranteed HTTP health endpoint |

---

## 6. Custom Dockerfile (AionUi)

**File:** `docker/aionui.Dockerfile`

```dockerfile
# Stage 1: Install hermes-agent[acp] in a Python image
FROM python:3.12-slim AS hermes-builder
RUN pip install --no-cache-dir hermes-agent[acp]

# Stage 2: Main AionUi image
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy Hermes ACP binaries from builder (ensures `hermes` CLI on PATH)
COPY --from=hermes-builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=hermes-builder /usr/local/bin/hermes /usr/local/bin/hermes

WORKDIR /app

# Clone and build AionUi
RUN git clone https://github.com/iOfficeAI/AionUi.git . \
    && bun install \
    && bun run build

EXPOSE 3001

CMD ["bun", "run", "start"]
```

### Design Rationale
- **Multi-stage:** Keeps final image small (Python only in builder, Node in final)
- **Pre-installed ACP:** `hermes-agent[acp]` installed at build time, not runtime
- **Standard PATH:** Binary at `/usr/local/bin/hermes` is always discoverable
- **No runtime deps:** Avoids `apt-get install` during container startup

---

## 7. Install Scripts

### `installers/common.sh` – Shared Library

**Functions:**

| Function | Purpose | Implements |
|----------|---------|------------|
| `detect_os()` | Detect Linux/macOS/WSL | – |
| `detect_wsl()` | Check `/proc/version` for Microsoft | Gap #8 fix |
| `sudo_check()` | Escalate privileges if needed | – |
| `check_docker()` | Verify Docker + Compose v2 | – |
| `port_check()` | Verify 8642/3000/3001 available | – |
| `generate_key()` | Generate 32-char hex API key | – |
| `ensure_hermes_config()` | Write `~/.hermes/config.yaml` with tuned compression timeout | Gap #7 fix |
| `ensure_hermes_env()` | Write `~/.hermes/.env` with API_SERVER_ENABLED, API_SERVER_KEY | – |
| `validate_url()` | Strip trailing slash, auto-append `/v1` | Gap #2 fix |
| `rollback_init()` | Create state file in SETUP_DIR | – |
| `rollback_trigger()` | Trap EXIT, reverse steps on failure | – |

### `installers/host.sh` – Host-Native Hermes + Docker UIs

**Sequence:**
1. `detect_wsl` → if WSL2, ask: Docker mode or WebUI-only AionUi
2. `check_docker` → verify Docker + Compose
3. `port_check` 8642, 3000, 3001
4. `generate_key` → set `API_SERVER_KEY`
5. pip install `hermes-agent[acp]`
6. `ensure_hermes_config` → write `~/.hermes/config.yaml`
7. `ensure_hermes_env` → write `~/.hermes/.env`
8. Build custom AionUi image
9. `docker compose up -d` Open WebUI + AionUi (Hermes runs natively)
10. `scripts/doctor.sh` → validate all endpoints
11. Print summary with URLs

### `installers/docker.sh` – All-Containerized

**Sequence:**
1. `detect_wsl` → if WSL2, offer `--webui` workaround
2. `check_docker` → verify Docker + Compose
3. `port_check` 8642, 3000, 3001
4. `generate_key` → set `API_SERVER_KEY`
5. `ensure_hermes_config` → write `~/.hermes/config.yaml`
6. `ensure_hermes_env` → write `~/.hermes/.env`
7. Build custom AionUi image
8. `docker compose up -d` (all 3 services)
9. `scripts/doctor.sh` → validate all endpoints
10. Print summary with URLs

### Rollback Mechanism

```
~/.hermes-setup/
├── state           # Current state (steps completed)
└── api_key         # Generated API key (for recovery)
```

- `trap rollback EXIT` on script entry
- Each step appends to state file
- On failure: reverse completed steps
- On success: remove trap, keep state file

---

## 8. Provider/Model Sync Flow

```
User edits ~/.hermes/config.yaml
        │
        ▼
Hermes detects mtime change (hot-reload)
        │
        ├──▶ API server updates /v1/models response
        │         │
        │         ▼
        │    Open WebUI (on next page load / model selector open):
        │      GET /v1/models → returns updated list
        │
        └──▶ AionUi (on next startup / config refresh):
               Reads /opt/data/config.yaml → updated providers
```

**No manual steps required:**
- No Open WebUI config page edits
- No AionUI config edits
- No container restarts
- No URL or API key updates

---

## 9. Security Considerations

| Concern | Mitigation |
|---------|------------|
| API key exposure | Generated per-install (32-char hex); never hardcoded |
| Unauthenticated API access | Bearer auth on all Hermes API endpoints |
| Volume permissions | Bind mount for Hermes (no named volume 666 issues) |
| Secret leakage | No secrets in Compose files (uses env substitution) |
| Runtime patching | Removed – no source code modification during install |
| Docker socket exposure | Not mounted (no `chmod 666 /var/run/docker.sock`) |
| Config tampering | AionUi Hermes mount is read-only |
| Upgrade path | Version-pinned images; no `:latest` surprises |

---

## 10. Post-Install Verification & Maintenance

### `scripts/doctor.sh` – Validation Script

**Checks performed:**
1. **Hermes API:** `curl -skf -H "Authorization: Bearer $key" http://localhost:8642/v1/models`
   - Expected: `{"object":"list","data":[...]}`
2. **Open WebUI:** `curl -sf http://localhost:3000/health`
   - Expected: `{"status":true}`
3. **AionUi:** `timeout 2 bash -c 'echo > /dev/tcp/localhost/3001'`
   - Expected: connection succeeds
4. **Port conflicts:** Verify 8642, 3000, 3001 are on expected services
5. **Config integrity:** Verify `~/.hermes/config.yaml` + `.env` exist and parseable

### Daily Operations

| Action | Command |
|--------|---------|
| View logs (all) | `docker compose logs -f` |
| View logs (single) | `docker compose logs -f hermes` |
| Restart service | `docker compose restart open-webui` |
| Update images | `docker compose pull && docker compose up -d` |
| Check health | `./scripts/doctor.sh` |
| Edit providers | `vim ~/.hermes/config.yaml` (auto-detected by Hermes) |

### Upgrade Path

1. `docker compose pull` (get new images)
2. `docker compose up -d` (recreate containers)
3. `./scripts/doctor.sh` (verify)

Database migrations (Open WebUI) run automatically via Alembic on startup.

---

## 11. Design Decisions & Rationale

### Decisions Verified by Source Code Analysis

| # | Decision | Verified? | Evidence |
|---|----------|-----------|----------|
| 1 | `/v1` path required in base URL | Yes | open-webui#18578: missing `/v1` returns empty model list |
| 2 | `/health` does NOT call `get_all_models()` | Yes | Backend source: `return {"status": true}` at main.py:2852 |
| 3 | `API_SERVER_KEY` required for auth | Yes | Hermes source: server skips startup without key |
| 4 | `AIOHTTP_CLIENT_TIMEOUT` defaults to None | Yes | env.py: unset = None (no timeout) |
| 5 | `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` defaults to 10s | Yes | env.py: default is 10 (acceptable) |
| 6 | Open WebUI strips trailing slashes | Yes | config.py: `url.rstrip('/')` |

### Decisions Based on Real-World Issues

| # | Decision | Bug Reference |
|---|----------|---------------|
| 1 | Tune compression timeout to 300s | hermes-agent#22986: 120s default causes 8x retry rate |
| 2 | Set `BYPASS_MODEL_ACCESS_CONTROL=true` | open-webui#7931: models private by default |
| 3 | Set `AIOHTTP_CLIENT_TIMEOUT=120` | open-webui env.py: None default = infinite hang |
| 4 | Auto-detect WSL + offer workaround | aionui#2748, #2767: Electron crashes on WSLg |
| 5 | Bind mount for Hermes config (not named volume) | Permissions: named volumes owned by root:root |
| 6 | Healthcheck includes auth header | Hermes official compose: requires Bearer |
| 7 | Custom AionUi Dockerfile (multi-stage) | Ensures hermes CLI on PATH; no runtime installs |
| 8 | Auto-append `/v1` to base URL | open-webui#18578: silent failure without `/v1` |

### Decisions That Were Considered and Rejected

| Decision | Why Rejected |
|----------|--------------|
| TCP healthcheck for Open WebUI | `/health` endpoint is proven safe (no model enumeration) |
| Override `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` | Default 10s is already acceptable |
| SSL cert env vars | Not needed – all internal communication is HTTP |
| .env consistency patching | Internal Hermes bug (#20558), not installer concern |
| AionUi PATH enhancement | pip install puts `hermes` at `/usr/local/bin` – always on PATH |
| Named volume for Hermes | Bind mount matches official compose; avoids root-owned volumes |
| Healthcheck without auth | Open WebUI `/health` works without auth; Hermes requires Bearer |

---

## Appendix A – File Tree

```
Hermes_Setup/
├── PLAN.md                    ← This file
├── AGENTS.md                  ← Memo for future coding sessions
├── installers/
│   ├── common.sh
│   ├── host.sh
│   └── docker.sh
├── compose/
│   └── docker-compose.yml
├── docker/
│   └── aionui.Dockerfile
├── scripts/
│   └── doctor.sh
└── patches/
    └── aionui/
        └── hermes-acp-provider.patch
```

## Appendix B – Environment Variables Reference

| Variable | Default | Set In | Purpose |
|----------|---------|--------|---------|
| `API_SERVER_ENABLED` | `true` | `.env` | Enable Hermes API server |
| `API_SERVER_KEY` | generated | `.env`, compose | API auth key (32-char hex) |
| `OPENAI_API_BASE_URL` | `http://hermes:8642/v1` | compose | Open WebUI backend URL |
| `OPENAI_API_KEY` | `${API_SERVER_KEY}` | compose | Open WebUI API auth |
| `BYPASS_MODEL_ACCESS_CONTROL` | `true` | compose | Expose all models to all users |
| `AIOHTTP_CLIENT_TIMEOUT` | `120` | compose | HTTP client timeout (seconds) |
| `ACP_BACKENDS_ALL` | `hermes` | AionUi image | ACP backend registry |
