## 2026-05-24 — v1.1.0

Host-mode port collision fix: AionUi native default port (3000) no longer conflicts with Open WebUI.

### Fixed
- **Port collision in host mode**: AionUi's production server defaults to port 3000, same as Open WebUI Docker.
  Installer now auto-detects the conflict and maps Open WebUI to port 3001 instead. ([#1](https://github.com/blundrep7909/Hermes_Setup/issues/1))
- **`update.sh`** now uses `$D`/`$DC` Docker permission variables (same as installer), fixing failures when user isn't in the docker group.
- **`preflight_port_check`** in common.sh now accepts a mode parameter (`host` vs `docker`), correctly assigning port 3000 to AionUi in host mode.
- **`doctor.sh`** reads stored Open WebUI port from `~/.hermes-setup/ow_port` instead of hardcoding 3000.

### Added
- **Dynamic Open WebUI port**: `host.sh` detects if port 3000 is occupied after AionUi starts, and remaps Open WebUI to 3001 automatically.
- **Port persistence**: The chosen Open WebUI host port is saved to `~/.hermes-setup/ow_port` for `doctor.sh` and `update.sh` to use.

---

# Version History

## 2026-05-24 — v1.0.0

Full one-line installer for Hermes Agent + Open WebUI + AionUi (host mode).

### Added
- One-line `curl ... | bash` installer for host mode (Hermes + AionUi native, Open WebUI Docker)
- Preflight port check before any changes (`/dev/tcp` + `ss -tlnpH` + Docker canary)
- Non-interactive TTY guard — skips confirmation prompt when piped
- Docker sudo fallback: `docker info` → `sudo -u $USER` → `sudo -n`
- WSL2 detection with multi-iface IP resolution (`eth0` → `eth1` → `bond0`) for Docker host access
- systemd user services + nohup PID fallback for Hermes + AionUi
- AionUi web-only production build (`vite build renderer` + `esbuild server`)
- Hermes API health wait loop (up to 12 attempts)
- Open WebUI health wait loop (up to 12 attempts, 60s total)
- Docker port retry loop (5 attempts, 3s delay, checks `docker inspect` status)
- Zero-residue uninstall: removes all files, services, Docker resources
- Post-install doctor.sh (10 checks: API, CLI, services, ports, config)
- UPDATE.md for update instructions
- AGENTS.md context file

### Fixed
- Open WebUI image tag `0.9.17` → `latest` (GHCR has no semver tags)
- `hermes-agent[acp,messaging]` → pip fallback to `[acp]` + `aiohttp` for VPS without `libsodium`/`libffi`
- `PASS++` → `++PASS` in doctor.sh (pre-increment avoids false `||` fallback)
- AionUi process check: `bun.*start.*webui` → `bun.*server:start` (production command)
- Uninstall docker permission fallback: all `docker` → `$D`/`$DC`
- Update.sh includes `aiohttp` in pip install
- `local` keyword outside function in host.sh
- Raw `ss` output for root-owned Docker ports (shows process name with sudo fallback)
- Port 3000 race condition in WSL2 (docker-proxy stale state) → retry + inspect

### Pushed Commits
```
7e9c299 fix: check container status instead of exit code for docker run
61cf3a4 fix: remove local keyword (not in function)
0bfe112 fix: retry docker run 5x with 3s delay for port 3000 race condition
365ee0b fix: add Docker port canary for stale docker-proxy in WSL2
d27fb66 fix: show owning process for root-owned ports via sudo fallback
1ce22fb fix: wait for Open WebUI health before doctor (race condition on first run)
27e4127 fix: preflight port check before rollback, pip fallback, port owner display
30d51a3 fix: uninstall uses $D/$DC for docker permission fallback
f701e10 fix: doctor.sh PASS++→++PASS, AionUi process check pattern
589fa00 fix: skip confirmation prompt when non-interactive
a5fac55 fix: install hermes-agent with [messaging] extra for aiohttp
1b4e048 fix: AionUi web-only production build, bun PATH, production server start
a457e0d fix: open-webui image tag 0.9.17→latest, docker sudo fallback
6566c1b fix: curl|bash pipe detection, update.sh grep false match
32c80ae fix: cosmetic bugs — paths, labels, dedup rollback
f8f774a Fix: clone repo first, then run installer (curl|bash incompatible)
5936b2a Add Docker daemon check
419a056 Add proactive systemd detection + nohup PID fallback
9e11582 Initial setup
```
