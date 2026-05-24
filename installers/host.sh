#!/usr/bin/env bash
set -euo pipefail

# Detect pipe mode (curl ... | bash) — BASH_SOURCE[0] is empty/unset
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Pipe mode detected — cloning Hermes_Setup repo..."
    TMP_DIR=$(mktemp -d)
    git clone --depth=1 https://github.com/blundrep7909/Hermes_Setup.git "$TMP_DIR"
    exec bash "$TMP_DIR/installers/host.sh" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

header "Hermes Setup – Host Mode (Native Hermes + AionUi, Docker Open WebUI)"
echo ""

validate_home

# ─── Pre-Install Plan Display (fix #20) ────────────────────────────────
header "Pre-Install Plan — What will be installed on YOUR system"
echo ""
echo "  SYSTEM-LEVEL (requires sudo once):"
echo "    • /var/lib/systemd/linger/$(whoami)  — enables user services after logout (if systemd available)"
echo "    • Docker image (1 pull)"
echo ""
echo "  USER-LEVEL (in \$HOME — fully reversible):"
echo "    • ~/.hermes-venv/          Python venv with hermes-agent[acp,messaging] (~200MB)"
echo "    • ~/hermes-aionui/         AionUi git clone + bun build (~500MB)"
echo "    • ~/.hermes/               Hermes config (~10KB)"
echo "    • ~/.hermes-setup/         Installer metadata + PID files (~10KB)"
echo "    • ~/.bun/                  Bun runtime if not already installed (~300MB)"
echo "    • ~/.local/bin/hermes      Symlink to hermes CLI"
echo "    • ~/.config/systemd/user/  2 systemd service files (if systemd available)"
echo "    • ~/.hermes-setup/pids/    PID files for nohup fallback (if systemd unavailable)"
echo "    • ~/.bashrc / .zshrc       3 lines (PATH + env sourcing)"
echo "    • Docker volume            1 (open-webui-data)"
echo ""
echo "  Total disk: ~3.5GB"
echo "  All of this is COMPLETELY REVERSIBLE via: bash ~/Hermes_Setup/scripts/uninstall.sh"
echo ""
if [[ -t 0 ]]; then
  read -rp "Proceed with installation? [Y/n] " REPLY
  if [[ "$REPLY" =~ ^[Nn] ]]; then
    info "Cancelled."
    exit 0
  fi
else
  info "Non-interactive — skipping confirmation prompt"
fi

# ─── Pre-flight port check (BEFORE rollback — fail cleanly, no rollback)
preflight_port_check

# ─── Prerequisites ─────────────────────────────────────────────────────
rollback_init
rollback_step "detection"

OS="$(detect_os)"
WSL="$(detect_wsl)"
info "OS: $OS | Platform: $WSL"

if [[ "$WSL" == "wsl2" ]]; then
  warn "WSL2 detected."
  warn "  Hermes + AionUi will run natively in WSL2."
  warn "  Open WebUI will run in Docker. Make sure Docker Desktop WSL2 backend is enabled."
fi

check_disk_space 3500
check_docker

rollback_step "systemd_check"
check_systemd

# ─── Generate Credentials ─────────────────────────────────────────────
rollback_step "keygen"
generate_key

# ─── Python Version Check (fix #9) ────────────────────────────────────
rollback_step "python_check"
PYTHON=""
for py in python3.12 python3.11 python3.10 python3; do
  if "$py" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
    PYTHON="$py"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  error "Python 3.10+ not found. Install Python 3.10 or later."
  exit 1
fi
info "Using Python: $($PYTHON --version)"

# ─── Create Hermes venv + install ─────────────────────────────────────
rollback_step "venv_created"
if [[ -d "$HOME/.hermes-venv" ]]; then
  info "Hermes venv already exists at ~/.hermes-venv"
else
  info "Creating Python venv at ~/.hermes-venv..."
  "$PYTHON" -m venv "$HOME/.hermes-venv"
fi

if "$HOME/.hermes-venv/bin/python" -c "import hermes_agent" 2>/dev/null; then
  info "hermes-agent already installed in venv"
else
  info "Installing hermes-agent[acp,messaging] in venv..."
  if "$HOME/.hermes-venv/bin/pip" install --no-cache-dir hermes-agent[acp,messaging]; then
    info "hermes-agent[acp,messaging] installed"
  else
    warn "hermes-agent[acp,messaging] failed — installing [acp] + aiohttp separately"
    warn "  Messaging platforms (telegram, discord, slack) will NOT be available."
    warn "  To add them later: pip install hermes-agent[messaging]"
    "$HOME/.hermes-venv/bin/pip" install --no-cache-dir hermes-agent[acp] aiohttp
  fi
fi

HERMES_BIN="$HOME/.hermes-venv/bin/hermes"
info "Hermes CLI: $HERMES_BIN"

# Add to ~/.local/bin for PATH access
mkdir -p "$HOME/.local/bin"
ln -sf "$HERMES_BIN" "$HOME/.local/bin/hermes" 2>/dev/null || true

# ─── Write Configs ────────────────────────────────────────────────────
rollback_step "config_written"
ensure_hermes_config
ensure_hermes_env

# ─── Persist Mode ─────────────────────────────────────────────────────
store_mode "host"

# ─── Install AionUi Natively (Option C) ──────────────────────────────
rollback_step "aionui_build"
AIONUI_DIR="$HOME/hermes-aionui"

# Track bun pre-existing state (fix #11)
if command -v bun &>/dev/null || [[ -f "$HOME/.bun/bin/bun" ]]; then
  touch "$SETUP_DIR/bun_pre_existing"
else
  rm -f "$SETUP_DIR/bun_pre_existing"
  info "Installing bun (JavaScript runtime for AionUi)..."
  curl -fsSL https://bun.sh/install | bash
fi

BUN_BIN=""
for b in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun" "$(command -v bun 2>/dev/null)"; do
  if [[ -x "$b" ]]; then BUN_BIN="$b"; break; fi
done
[[ -z "$BUN_BIN" ]] && BUN_BIN="$HOME/.bun/bin/bun"

# Ensure bun bin dir is on PATH (needed for bunx, etc.)
export PATH="$HOME/.bun/bin:$PATH"

if [[ -d "$AIONUI_DIR" ]]; then
  info "AionUi directory exists at $AIONUI_DIR"
  if [[ ! -f "$AIONUI_DIR/node_modules/.package-lock.json" ]]; then
    info "Dependencies not installed — running bun install..."
    "$BUN_BIN" install --cwd "$AIONUI_DIR"
  fi
else
  info "Cloning AionUi to $AIONUI_DIR..."
  git clone --depth=1 https://github.com/iOfficeAI/AionUi.git "$AIONUI_DIR"
  info "Installing dependencies (this may take a minute)..."
  "$BUN_BIN" install --cwd "$AIONUI_DIR"
  info "Building AionUi web renderer..."
  "$BUN_BIN" run --cwd "$AIONUI_DIR" build:renderer:web
  info "Building AionUi server..."
  "$BUN_BIN" run --cwd "$AIONUI_DIR" build:server
fi

# ─── Create Start Scripts (fix #8: --replace, fix #19: dynamic bun) ──
rollback_step "start_scripts"
mkdir -p "$SETUP_DIR"

cat > "$SETUP_DIR/hermes-start.sh" << 'HERMES_START_EOF'
#!/usr/bin/env bash
source ~/.hermes/.env
exec ~/.hermes-venv/bin/hermes gateway run --replace
HERMES_START_EOF
chmod +x "$SETUP_DIR/hermes-start.sh"

cat > "$SETUP_DIR/aionui-start.sh" << AIONUI_START_EOF
#!/usr/bin/env bash
export PATH="\$HOME/.bun/bin:\$PATH"
BUN_BIN=""
for b in "\$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun"; do
  [[ -x "\$b" ]] && { BUN_BIN="\$b"; break; }
done
[[ -z "\$BUN_BIN" ]] && BUN_BIN="\$HOME/.bun/bin/bun"
cd "\$HOME/hermes-aionui" && exec "\$BUN_BIN" run server:start:prod
AIONUI_START_EOF
chmod +x "$SETUP_DIR/aionui-start.sh"

# ─── Systemd User Services / Nohup Fallback ─────────────────────────
if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
  # ── Systemd Path ────────────────────────────────────────────────────
  rollback_step "systemd_hermes"
  SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SYSTEMD_USER_DIR"

  cat > "$SYSTEMD_USER_DIR/hermes-gateway.service" << 'SERVICE_HERMES_EOF'
[Unit]
Description=Hermes Agent Gateway (API Server + ACP)
After=network.target

[Service]
Type=simple
EnvironmentFile=%h/.hermes/.env
ExecStart=%h/.hermes-venv/bin/hermes gateway run --replace
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SERVICE_HERMES_EOF

  rollback_step "systemd_aionui"
  cat > "$SYSTEMD_USER_DIR/aionui-webui.service" << 'SERVICE_AIONUI_EOF'
[Unit]
Description=AionUi WebUI (Headless)
After=network.target hermes-gateway.service
BindsTo=hermes-gateway.service

[Service]
Type=simple
ExecStart=%h/.hermes-setup/aionui-start.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SERVICE_AIONUI_EOF

  rollback_step "linger_enabled"
  sudo loginctl enable-linger "$(whoami)" 2>/dev/null || true

  systemctl --user daemon-reload
  info "Starting Hermes gateway (systemd)..."
  systemctl --user enable --now hermes-gateway.service || {
    warn "systemd hermes-gateway failed — falling back to nohup"
    SYSTEMD_AVAILABLE=false
    nohup "$SETUP_DIR/hermes-start.sh" > "$HOME/.hermes/hermes-gateway.log" 2>&1 &
    echo $! > "$SETUP_DIR/pids/hermes-gateway.pid"
  }

  info "Starting AionUi WebUI (systemd)..."
  systemctl --user enable --now aionui-webui.service 2>/dev/null || {
    warn "systemd aionui-webui failed — falling back to nohup"
    SYSTEMD_AVAILABLE=false
    nohup "$SETUP_DIR/aionui-start.sh" > "$HOME/hermes-aionui/aionui-webui.log" 2>&1 &
    echo $! > "$SETUP_DIR/pids/aionui-webui.pid"
  }
else
  # ── Nohup Path ─────────────────────────────────────────────────────
  rollback_step "nohup_start"
  mkdir -p "$SETUP_DIR/pids"

  info "Systemd not available — starting Hermes via nohup..."
  nohup "$SETUP_DIR/hermes-start.sh" > "$HOME/.hermes/hermes-gateway.log" 2>&1 &
  echo $! > "$SETUP_DIR/pids/hermes-gateway.pid"

  info "Systemd not available — starting AionUi via nohup..."
  nohup "$SETUP_DIR/aionui-start.sh" > "$HOME/hermes-aionui/aionui-webui.log" 2>&1 &
  echo $! > "$SETUP_DIR/pids/aionui-webui.pid"
fi

# Wait for Hermes API
info "Waiting for Hermes API to be ready..."
for i in $(seq 1 15); do
  if curl -skf -H "Authorization: Bearer $API_SERVER_KEY" http://localhost:8642/v1/models >/dev/null 2>&1; then
    info "Hermes API ready (attempt $i)"
    break
  fi
  sleep 2
done

# ─── Start Open WebUI (Docker) ──────────────────────────────────────
rollback_step "docker_run"
OPENWEBUI_URL="http://host.docker.internal:8642/v1"
if [[ "$WSL" == "wsl2" ]]; then
  # Fix #14: try multiple interface names
  WSL2_IP=""
  for iface in eth0 eth1 bond0; do
    WSL2_IP="$(ip addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)"
    [[ -n "$WSL2_IP" ]] && break
  done
  OPENWEBUI_URL="http://${WSL2_IP:-host.docker.internal}:8642/v1"
fi

if $D ps --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
  info "Open WebUI container already running"
else
  $D rm -f open-webui 2>/dev/null || true
  info "Starting Open WebUI container..."
  local openwebui_started=false
  for attempt in 1 2 3 4 5; do
    if $D run -d \
      --name open-webui \
      --restart unless-stopped \
      -p 3000:8080 \
      --add-host host.docker.internal:host-gateway \
      -v open-webui-data:/app/backend/data \
      -e OPENAI_API_BASE_URL="$OPENWEBUI_URL" \
      -e OPENAI_API_KEY="$API_SERVER_KEY" \
      -e BYPASS_MODEL_ACCESS_CONTROL=true \
      -e AIOHTTP_CLIENT_TIMEOUT=120 \
      "$OPENWEBUI_IMAGE" 2>/dev/null; then
      openwebui_started=true
      break
    fi
    warn "Port 3000 still busy (attempt $attempt/5) — retrying in 3s..."
    sleep 3
    $D rm -f open-webui 2>/dev/null || true
  done
  if [[ "$openwebui_started" != "true" ]]; then
    error "Could not bind port 3000 after 5 attempts — another process is holding it"
    exit 125
  fi
fi

# ─── Wait for Open WebUI health ───────────────────────────────────────
info "Waiting for Open WebUI to be ready..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:3000/health >/dev/null 2>&1; then
    info "Open WebUI ready (attempt $i)"
    break
  fi
  sleep 5
done

# ─── Verification ─────────────────────────────────────────────────────
rollback_step "verify"
info "Running post-install verification..."
export API_SERVER_KEY
bash "$DOCTOR_SCRIPT" || {
  warn "Some checks failed. Review output above."
}

# ─── Shell rc integration (fix #12-13: marker block, no duplicates) ──
RC_MARKER_START="# --- Hermes Setup (auto-generated, do not edit) ---"
RC_MARKER_END="# --- /Hermes Setup ---"
RC_BLOCK="${RC_MARKER_START}
export PATH=\"\$HOME/.hermes-venv/bin:\$PATH\"
[ -f \"\$HOME/.hermes/.env\" ] && source \"\$HOME/.hermes/.env\"
${RC_MARKER_END}"

for rc_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  if [[ -f "$rc_file" ]]; then
    if grep -Fq "$RC_MARKER_START" "$rc_file" 2>/dev/null; then
      continue  # already present, skip
    fi
    printf "\n%s\n" "$RC_BLOCK" >> "$rc_file"
    info "Added Hermes block to $rc_file"
  fi
done

# ─── Summary (fix #18: explain ACP native advantage) ──────────────────
trap - EXIT
echo ""
header "Installation Complete"
echo ""
echo "  Mode:         Host — fully reversible via uninstall.sh"
echo ""
echo "  Hermes API:   http://localhost:8642/v1"
echo "  Open WebUI:   http://localhost:3000"
echo "  AionUi WebUI: http://localhost:3001"
echo ""
echo "  ✅ ACP agents run natively on the host"
echo "     └── Full access to: host filesystem, processes, network"
echo ""
if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
  echo "  Services:"
  echo "    Hermes  → systemctl --user status hermes-gateway"
  echo "    AionUi  → systemctl --user status aionui-webui"
  echo ""
  echo "  Logs:"
  echo "    Hermes  → journalctl --user -u hermes-gateway -f"
  echo "    AionUi  → journalctl --user -u aionui-webui -f"
else
  echo "  Services: (nohup — no systemd)"
  echo "    Hermes  → PID: $(cat "$SETUP_DIR/pids/hermes-gateway.pid" 2>/dev/null || echo 'N/A')"
  echo "    AionUi  → PID: $(cat "$SETUP_DIR/pids/aionui-webui.pid" 2>/dev/null || echo 'N/A')"
  echo ""
  echo "  Logs:"
  echo "    Hermes  → cat ~/.hermes/hermes-gateway.log"
  echo "    AionUi  → cat ~/hermes-aionui/aionui-webui.log"
fi
echo "    WebUI   → docker logs -f open-webui"
echo ""
echo "  To configure providers:"
echo "    source ~/.hermes/.env && ~/.hermes-venv/bin/hermes setup"
echo ""
echo "  To uninstall (zero residue): bash ~/Hermes_Setup/scripts/uninstall.sh"
echo "  To verify:                   bash ~/Hermes_Setup/scripts/doctor.sh"
echo ""
