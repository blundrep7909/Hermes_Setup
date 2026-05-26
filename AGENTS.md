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
- Docker is auto-installed by the installer if missing (uses apt for Debian/Ubuntu, dnf for Fedora, etc.)
- User is automatically added to the `docker` group, so `sudo` is not needed for Docker commands
- If the current shell doesn't pick up the new group, `newgrp docker` or re-login
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
- **Platform**: WSL2 on Ubuntu
- **OS**: ubuntu
- **Docker**: Auto-installed by installer, user added to docker group
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

## Key Fixes Referenced in VERSION.md
See [VERSION.md](./VERSION.md) for the full changelog. Key fixes this session:
- `prompt_install_mode()` stdout leak fix — all display text now goes to stderr
- Port 3000 Docker canary replaced `ss`-based detection (invisible in WSL2)
