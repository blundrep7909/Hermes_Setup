## 2026-06-05 — v1.2.0

Bun/Node.js compatibility fixes for non-interactive and WSL2 environments.
Installation summary now shows AionUi admin credentials.

### Added
- **AionUi admin credentials displayed in install summary**:
  After installation, the script retrieves the AionUi admin username and password
  from the aioncore API and shows them in a box at the end of the output.
  Password is generated fresh via reset-password API.

### Fixed
- **`node scripts/prepareAioncore.js` replaced with `"$BUN_BIN" scripts/prepareAioncore.js`**:
  Node.js is not guaranteed to be installed. Bun runtime is used instead for downloading the aioncore binary.
- **`aionui-start.sh` uses `bun run scripts/webui.ts` instead of `cross-env tsx`**:
  `tsx` (Node.js TypeScript executor) is incompatible with Bun. Bun's native TypeScript support works directly.
- **`aionui-start.sh` for loop now includes `$(command -v bun 2>/dev/null)` fallback**:
  The generated start script was missing the `command -v bun` fallback that exists in the main installer.
- **python3-venv install now tries `apt-get install` without sudo as fallback**:
  In non-interactive mode or WSL2, `sudo` may hang. The installer now falls back to non-sudo `apt-get`, then provides clear manual instructions.
- **`API_SERVER_HOST=0.0.0.0` added to `.env`**:
  The Hermes API server defaults to binding on `127.0.0.1:8642`, which is inaccessible from Docker containers.
  Adding `API_SERVER_HOST=0.0.0.0` makes the gateway bind on all interfaces, allowing
  Open WebUI (and other Docker containers) to reach the Hermes API via the WSL2 IP address.
- **OpenCode CLI installed and registered**:
  The installer now downloads OpenCode CLI and adds `~/.opencode/bin` to `~/.profile`
  so aioncore can detect it as an ACP agent. OpenCode appears in AionUi's agent list
  with model/mode configuration available in settings.
- **WSL xdg-open wrapper for Windows default apps**:
  On WSL2, `xdg-open` (used by aioncore's "Open in system app" feature) only opens files
  with Linux apps. The installer now creates `/usr/local/bin/xdg-open` that converts Linux
  paths to Windows paths via `wslpath -w` and opens them with `explorer.exe`, making files
  open in the correct Windows default application (e.g., browser for HTML, image viewer
  for PNG, etc.).

---

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
