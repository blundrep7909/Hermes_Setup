# Hermes Stack — One-Line AI Agent Stack

> **Deploy Hermes Agent + Open WebUI + AionUi in one command.**
> Host-native or all-Docker — your choice. Hermes Agent is the single source of truth for provider/model config.

## Quick Install

### Host Mode — Hermes + AionUi native, Open WebUI in Docker

```bash
git clone --depth=1 https://github.com/blundrep7909/Hermes_Setup.git ~/Hermes_Setup && bash ~/Hermes_Setup/installers/host.sh
```

**What you get:**
- **Hermes Agent** — installed in Python venv at `~/.hermes-venv/`, auto-started via systemd (or nohup)
- **AionUi** — cloned + built at `~/hermes-aionui/`, auto-started via systemd (or nohup)
- **Open WebUI** — single Docker container
- **ACP agents** run natively → full host access (filesystem, processes, network)

### Docker Mode — Everything containerized

```bash
git clone --depth=1 https://github.com/blundrep7909/Hermes_Setup.git ~/Hermes_Setup && bash ~/Hermes_Setup/installers/docker.sh
```

> 📁 The cloned repo at `~/Hermes_Setup/` is used for management commands:
> `bash ~/Hermes_Setup/scripts/doctor.sh`, `uninstall.sh`, `update.sh`, `backup.sh`.
> Keep it around — it's only ~200KB.

## Architecture

### Host Mode

```
Host:
├── Hermes Agent (venv, systemd)    ← ACP → full host control
│   └── API Server (:8642/v1)
├── AionUi (native, systemd)         ← runs headless, no GUI needed
│   └── WebUI (:3001)
└── Open WebUI (Docker container)    ← connects via host.docker.internal
    └── HTTP → Hermes API (:8642/v1)
```

### Docker Mode

```
Docker:
├── hermes (container)    ← API + ACP
├── open-webui (container)
└── aionui (container)    ← custom build with hermes-agent[acp]
```

## Post-Install

1. Configure your AI provider:
   ```bash
   # Host mode
   source ~/.hermes/.env && ~/.hermes-venv/bin/hermes setup

   # Docker mode
   docker exec -it hermes /opt/hermes/.venv/bin/hermes setup
   ```
2. Open http://localhost:3000 (Open WebUI) or http://localhost:3001 (AionUi)
3. Models appear automatically — no manual URL or key config needed

## Service Reference

| Service | Port | URL | Host mode | Docker mode |
|---------|------|-----|-----------|-------------|
| Hermes API | 8642 | http://localhost:8642/v1 | Native (systemd or nohup) | Container |
| Open WebUI | 3000 | http://localhost:3000 | Docker (single) | Container |
| AionUi WebUI | 3001 | http://localhost:3001 | Native (systemd or nohup) | Container |

## Management

All commands below run from the cloned repo directory (`~/Hermes_Setup/`). Auto-detect host or docker mode from `~/.hermes-setup/state`.

### Update

```bash
# Auto-detect mode
bash ~/Hermes_Setup/scripts/update.sh

# Force specific mode
bash ~/Hermes_Setup/scripts/update.sh --host
bash ~/Hermes_Setup/scripts/update.sh --docker
```

| Mode | Hermes | AionUi | Open WebUI |
|------|--------|--------|------------|
| Host | pip upgrade in venv | git pull + rebuild | docker pull + recreate |
| Docker | compose pull | compose pull | compose pull |

### Backup

```bash
# Auto-detect mode — backs up to ~/hermes-backups/
bash ~/Hermes_Setup/scripts/backup.sh [--host | --docker]

# Custom output directory
BACKUP_DIR=/path/to/backups bash ~/Hermes_Setup/scripts/backup.sh
```

| Backup source | Host mode | Docker mode |
|--------------|-----------|-------------|
| `~/.hermes/` (config) | ✅ tar.gz | ✅ tar.gz |
| `~/.hermes-setup/` (meta) | ✅ tar.gz | ✅ tar.gz |
| Docker volume `open-webui-data` | ✅ tar.gz | ✅ tar.gz |
| Docker volume `aionui-data` | ❌ (no container) | ✅ tar.gz |
| `~/hermes-aionui/` (source) | ✅ tar.gz | ❌ (in container) |
| Hermes venv packages | ✅ pip freeze | ❌ (in container) |

### Uninstall

```bash
# Interactive (asks confirmation, preserves data by default)
bash ~/Hermes_Setup/scripts/uninstall.sh [--host | --docker]

# Delete everything without asking
bash ~/Hermes_Setup/scripts/uninstall.sh --force
```

| What gets removed | Without `--force` | With `--force` |
|-------------------|-------------------|----------------|
| Systemd services / containers | ✅ Yes | ✅ Yes |
| Open WebUI container | ✅ Yes | ✅ Yes |
| Config files (`~/.hermes/`) | ❌ Asks first | ✅ Deleted |
| Docker volumes (data) | ❌ Asks first | ✅ Deleted |
| Hermes venv (`~/.hermes-venv/`) | ⚠️ Host mode only | ⚠️ Host mode only |
| AionUi source (`~/hermes-aionui/`) | ❌ Asks first | ✅ Deleted |

### Daily Operations

```bash
# Host mode
systemctl --user status hermes-gateway      # Check Hermes (systemd)
systemctl --user status aionui-webui        # Check AionUi (systemd)
cat ~/.hermes-setup/pids/hermes-gateway.pid # Check Hermes PID (nohup)
cat ~/.hermes-setup/pids/aionui-webui.pid   # Check AionUi PID (nohup)
journalctl --user -u hermes-gateway -f      # Hermes logs (systemd only)
journalctl --user -u aionui-webui -f        # AionUi logs (systemd only)
docker logs -f open-webui                   # Open WebUI logs

# Docker mode
docker compose -f ~/Hermes_Setup/compose/docker-compose.yml logs -f

# Verify installation
bash ~/Hermes_Setup/scripts/doctor.sh
```

## Data Safety

| Component | Storage | Update-safe? | Backup covers? |
|-----------|---------|--------------|----------------|
| Hermes config | `~/.hermes/` (bind mount) | ✅ Yes | ✅ Yes |
| Open WebUI | Volume `open-webui-data` | ✅ Yes | ✅ Yes |
| AionUi (host) | `~/hermes-aionui/` + `~/.config/AionUi/` | ✅ Yes | ✅ Config only |
| AionUi (docker) | Volume `aionui-data` | ✅ Yes | ✅ Yes |
| Setup metadata | `~/.hermes-setup/` | ✅ Yes | ✅ Yes |

Data is only lost if you explicitly run `uninstall.sh --force` or `docker compose down -v`.

## File Structure

```
Hermes_Setup/
├── README.md
├── AGENTS.md                    # Memo for future coding sessions
├── PLAN.md                      # Full architecture plan
├── .env.example
├── installers/
│   ├── common.sh                # 12 shared functions + rollback
│   ├── host.sh                  # Host-mode installer (venv + native AionUi)
│   └── docker.sh                # Docker-mode installer (all containerized)
├── compose/
│   └── docker-compose.yml       # 3-service Compose (docker mode only)
├── docker/
│   └── aionui.Dockerfile        # Multi-stage AionUi build (docker mode)
├── scripts/
│   ├── doctor.sh                # Post-install validation (mode-aware)
│   ├── update.sh                # Update all components (mode-aware)
│   ├── backup.sh                # Backup config + volumes (mode-aware)
│   ├── uninstall.sh             # Remove stack (mode-aware, interactive)
│   ├── hermes-start.sh          # Start Hermes gateway (host mode)
│   └── aionui-start.sh          # Start AionUi WebUI (host mode)
└── patches/
    └── aionui/
        └── hermes-acp-provider.patch  # Config reference
```
