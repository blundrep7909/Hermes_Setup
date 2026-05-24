# Hermes Setup – AGENTS

## Architecture SSOT
Hermes Agent is the single source of truth. Both UIs (Open WebUI, AionUi) consume
Hermes' OpenAI-compatible API. Never replicate provider/model config in UI configs.

## Critical URL Rule
Always append `/v1` to `OPENAI_API_BASE_URL`. Without it, Open WebUI silently
returns zero models. Strip trailing slashes before appending.

## Healthcheck Safety
Open WebUI `/health` is a trivial `return {"status": true}` — no model enumeration,
no DB queries. Safe to use as Docker healthcheck. Hermes healthcheck MUST include
Bearer auth header.

## WSL2 Docker Caveats
- Docker works only via `sudo -u gomugatling docker` (user not in docker group)
- `sudo -n` fails (no NOPASSWD), `check_docker()` falls through to `sudo -u $USER`
- Port 3000 `ss`/`lsof` shows NO process in WSL2 because docker-proxy runs in a separate network namespace in the Docker VM (not visible from the WSL2 Linux side)
- The ONLY reliable way to check if Docker can bind port 3000 is a Docker canary: `$D run --rm -p 3000:8080 alpine:3.19 true`
- docker-proxy may take 60-120 seconds to release port after container removal (kernel-level TCP TIME_WAIT that's invisible from WSL2 side)
- `sudo service docker restart` is the only reliable way to clear a stalled docker-proxy on port 3000
- After restarting Docker, wait ~15 seconds before attempting to bind the port again
- No alternative — `ss -tlnpH`, `lsof -i :3000`, and `/dev/tcp` ALL miss the docker-proxy in WSL2

## File Map
| Path | Purpose |
|---|---|
| `installers/common.sh` | Shared functions: port check, detection, install mode prompt, Open WebUI container start, rollback, config |
| `installers/host.sh` | Host-mode installer (native Hermes + AionUi, Docker Open WebUI) |
| `installers/docker.sh` | All-containerized installer (Hermes + Open WebUI + AionUi in Docker Compose) |
| `scripts/uninstall.sh` | Zero-residue uninstall (stop services, rm files, rm Docker resources) |
| `scripts/doctor.sh` | Post-install validation (10 checks: API, CLI, services, ports, config) |
| `compose/` | Docker Compose files for all-containerized mode |

## Applied Bug Fixes (chronological)

### v1.0.0 — Foundational
- `auxiliary.compression.timeout: 300` — prevents 8x retry rate (hermes-agent#22986)
- `BYPASS_MODEL_ACCESS_CONTROL=true` — models not private by default (open-webui#7931)
- `AIOHTTP_CLIENT_TIMEOUT=120` — default None = infinite hang (open-webui env.py)
- AionUi runs headless `--webui` always (host mode); WSL detection uses multi-iface IP (eth0→eth1→bond0) for Open WebUI docker host access (aionui#2748)

### v1.0.1 — Installer Reliability
- Pipe-mode (`curl ... | bash`) detection → clone repo first, then exec installer
- Docker sudo fallback: `docker info` → `sudo -u $USER` → `sudo -n`
- Docker port retry loop: 5 attempts, retry on `$D inspect` status check (not exit code)
- Open WebUI image tag `0.9.17` → `latest` (GHCR has no semver tags)
- pip fallback: `hermes-agent[acp,messaging]` → `[acp]` + `aiohttp` (for VPS without libsodium/libffi)
- AionUi web-only production build (vite build renderer + esbuild server, no electron)
- systemd user services + nohup PID fallback for Hermes + AionUi

### v1.0.2 — Preflight + Existing Installation Detection
- Preflight port check before any changes (`/dev/tcp` + `ss -tlnpH` + Docker canary for port 3000)
- Non-interactive TTY guard: `[[ -t 0 ]]` → skip confirmation prompt when piped
- Existing installation detection via `detect_existing_installation()` + `prompt_install_mode()`
- Install mode prompt: (U)pdate / (F)resh / (C)ancel with `--fresh`/`--update` flag overrides
- `FORCE_UPGRADE` mode for update: `pip --upgrade`, `git pull`, `docker pull`
- Rollback guarded by `[[ -f "$STATE_FILE" ]]` — no-op in update mode (no rollback_init)
- Zero-residue uninstall: removes all files, services, Docker resources

### v1.0.3 — Port 3000 Docker Canary (THIS SESSION)
- Replaced `ss`-based stale docker-proxy detection with Docker canary (`$D run --rm -p 3000:8080 alpine:3.19 true`) — works in WSL2 where ss/lsof miss the proxy
- Canary loop: 40 attempts × 3s = 120s timeout, shows progress dots (.........)
- Container start retry: 10 attempts × 10s, captures docker stderr on bind failure, dumps container logs on crash failure
- `libsecret-1-dev` added as AionUi system dependency (fixes `keytar` native module build during `bun install` postinstall)

### v1.0.4 — Existing Installation Detection Fix (THIS SESSION)
- **Critical bug**: `prompt_install_mode()` sent ALL display text (header, options, prompt) to stdout, which was captured by `$(...)` — so `INSTALL_MODE` contained the full prompt UI string instead of just "update"/"fresh"/"cancel"
- **Fix**: All display lines now go to `>&2` (stderr); only the mode return value goes to stdout
- This caused the detection → prompt flow to never trigger (the case statement never matched)

## Avoid These Mistakes
- Do NOT use `OPENAI_BASE_URL` (wrong name; must be `OPENAI_API_BASE_URL`)
- Do NOT set `OPENAI_API_KEY=***` literal string
- Do NOT `chmod 666 /var/run/docker.sock`
- Do NOT source-patch Hermes at runtime
- Do NOT use SQL injection in password scripts
- Do NOT use named volumes for Hermes config (use bind mount)
- Do NOT use `ss` to check Docker port binding in WSL2 (docker-proxy is invisible from Linux side)
- Do NOT redirect `$D run -d` stderr to `/dev/null` without capturing the real error message
- Do NOT send prompt UI text to stdout when using `$()` for value capture

## Special Environment
- **User**: gomugatling
- **Sudo password**: rasah
- **Docker**: `sudo -u gomugatling docker` (user not in docker group)
- **Platform**: WSL2 on Ubuntu
- **OS**: ubuntu
- **Docker version**: 29.1.3
- **Python**: 3.14.4
- **Hermes agent**: v0.14.0
- **GitHub**: https://github.com/blundrep7909/Hermes_Setup

## Verification
Always run `~/Hermes_Setup/scripts/doctor.sh` after install to validate all endpoints.

## Key Commands
```bash
# Fresh install
curl -fsSL https://github.com/blundrep7909/Hermes_Setup/raw/main/installers/host.sh | bash
# Or with flags:
curl -fsSL https://github.com/blundrep7909/Hermes_Setup/raw/main/installers/host.sh | bash -s -- --fresh

# Uninstall (after successful install, ~/Hermes_Setup exists)
bash ~/Hermes_Setup/scripts/uninstall.sh --force

# Verify
bash ~/Hermes_Setup/scripts/doctor.sh

# Restart Docker (fixes stale port 3000 proxy in WSL2)
sudo service docker restart
```

## Known Remaining Issues
- Port 3000 docker-proxy can't be detected via `ss`/`lsof` in WSL2 (Docker VM namespace)
- Long wait (up to 120s) for stale docker-proxy to release port 3000 after container removal
- AionUi WebUI times out during keytar rebuild (mitigated by libsecret-1-dev, but postinstall may still log warnings)
- `sudo -u gomugatling` bypass needed for every Docker command (user not in docker group)
