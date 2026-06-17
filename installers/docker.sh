#!/usr/bin/env bash
set -euo pipefail

# Detect pipe mode (curl ... | bash) — BASH_SOURCE[0] is empty/unset
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Pipe mode detected — cloning Hermes_Setup repo..."
    TMP_DIR=$(mktemp -d)
    git clone --depth=1 https://github.com/blundrep7909/Hermes_Setup.git "$TMP_DIR"
    exec bash "$TMP_DIR/installers/docker.sh" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ─── Flag parsing ──────────────────────────────────────────────────────
FRESH_FLAG=false
UPDATE_FLAG=false
for arg in "$@"; do
  case "$arg" in
    --fresh)  FRESH_FLAG=true  ;;
    --update) UPDATE_FLAG=true ;;
  esac
done

header "Hermes Setup – Docker Mode (All Containerized)"
echo ""

validate_home

# ─── Cache sudo credentials (one password prompt, not many) ────────
if [[ -t 0 ]]; then
  info "One-time sudo authentication required for system-level changes..."
  sudo -v 2>&1 || warn "sudo not available or cancelled — system-level steps may fail"
fi

# ─── OS / Docker detection (before port check — $D must be correct) ────
OS="$(detect_os)"
WSL="$(detect_wsl)"
info "OS: $OS | Platform: $WSL"

if [[ "$WSL" == "wsl2" ]]; then
  warn "WSL2 detected. AionUi GUI won't work in Docker mode (no display)."
  warn "  This is expected — AionUi runs headless in Docker."
fi

check_docker

# ─── Pre-flight port check (BEFORE rollback — fail cleanly, no rollback)
preflight_port_check

# ─── 9Router port check ──────────────────────────────────────────────
info "Checking port 20128 (9Router)..."
if timeout 2 bash -c "echo > /dev/tcp/0.0.0.0/20128" 2>/dev/null; then
  error "Port 20128 (9Router) already in use"
  exit 1
fi
info "Port 20128 (9Router): available"

# ─── Detect existing installation → prompt mode ────────────────────────
EXISTING=$(detect_existing_installation)
DO_ROLLBACK=true
FORCE_UPGRADE=false
INSTALL_MODE="normal"

if [[ -n "$EXISTING" ]]; then
  INSTALL_MODE=$(prompt_install_mode "$EXISTING")
  case "$INSTALL_MODE" in
    cancel)
      info "Cancelled."
      exit 0
      ;;
    fresh)
      info "Uninstalling existing installation..."
      bash "$SCRIPT_DIR/../scripts/uninstall.sh" --docker --force
      info "Proceeding with fresh install..."
      ;;
    update)
      FORCE_UPGRADE=true
      DO_ROLLBACK=false
      header "Update Mode — upgrading existing components"
      echo ""
      ;;
  esac
fi

# ─── Prerequisites ─────────────────────────────────────────────────────
if [[ "$DO_ROLLBACK" == "true" ]]; then
  rollback_init
  rollback_step "detection"
fi

# ─── Generate Credentials ─────────────────────────────────────────────
rollback_step "keygen"
generate_key

# ─── Write Configs ────────────────────────────────────────────────────
rollback_step "config_written"
ensure_hermes_config
ensure_hermes_env

# ─── Persist Mode ─────────────────────────────────────────────────────
store_mode "docker"

# ─── Store ports for doctor.sh ─────────────────────────────────────
echo 3000 > "$SETUP_DIR/ow_port"
echo 3001 > "$SETUP_DIR/ai_port"

# ─── Deploy Containers ────────────────────────────────────────────────
if [[ "$FORCE_UPGRADE" == "true" ]]; then
  info "Pulling latest images..."
  $DC -f "$COMPOSE_DIR/docker-compose.yml" pull
  info "Recreating containers with latest images..."
else
  if [[ "$DO_ROLLBACK" == "true" ]]; then
    rollback_step "compose_build"
  fi
  info "Building AionUi Docker image (custom, with hermes-agent[acp])..."
  $DC -f "$COMPOSE_DIR/docker-compose.yml" build aionui

  if [[ "$DO_ROLLBACK" == "true" ]]; then
    rollback_step "compose_up"
  fi
fi
info "Starting all containers (Hermes + Open WebUI + AionUi + 9Router)..."
export API_SERVER_KEY
$DC -f "$COMPOSE_DIR/docker-compose.yml" up -d

# ─── Install OpenCode CLI (ACP agent for AionUi) ─────────────────────
rollback_step "opencode"
if command -v opencode &>/dev/null; then
  info "OpenCode already installed at $(command -v opencode)"
else
  info "Installing OpenCode CLI..."
  if curl -fsSL https://opencode.ai/install | bash; then
    info "OpenCode installed."
    if ! grep -q 'opencode/bin' "$HOME/.profile" 2>/dev/null; then
      cat >> "$HOME/.profile" << 'OPENCODE_PROFILE_EOF'

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
OPENCODE_PROFILE_EOF
      info "Added opencode PATH to ~/.profile"
    fi
  else
    warn "OpenCode install failed — skipping. AionUi won't detect opencode."
  fi
fi

# ─── Verification ─────────────────────────────────────────────────────
rollback_step "verify"
info "Waiting for services to be ready..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:3000/health >/dev/null 2>&1 && \
     curl -skf -H "Authorization: Bearer $API_SERVER_KEY" http://localhost:8642/v1/models >/dev/null 2>&1; then
    info "Services ready (attempt $i)"
    break
  fi
  sleep 5
done

# ─── 9Router readiness ──────────────────────────────────────────────
info "Waiting for 9Router to be ready..."
for i in $(seq 1 6); do
  if curl -sf http://localhost:20128/health >/dev/null 2>&1; then
    info "9Router ready (attempt $i)"
    break
  fi
  sleep 3
done

info "Running post-install verification..."
export API_SERVER_KEY
bash "$DOCTOR_SCRIPT" || {
  warn "Some checks failed. Review output above."
}

# ─── Summary ──────────────────────────────────────────────────────────
trap - EXIT
echo ""
header "Installation Complete"
echo ""
if [[ "$INSTALL_MODE" == "update" ]]; then
  echo "  Mode:         Docker (update) — existing containers upgraded"
else
  echo "  Mode:         Docker (all 3 in containers)"
fi
echo "  Hermes API:   http://localhost:8642/v1"
echo "  Open WebUI:   http://localhost:3000"
echo "  AionUi:       http://localhost:3001"
echo "  9Router:      http://localhost:20128"
echo ""
echo "  To configure providers:"
echo "    docker exec -it hermes /opt/hermes/.venv/bin/hermes setup"
echo ""
echo "  To configure 9Router:"
echo "    Open http://localhost:20128/dashboard in your browser"
echo ""
echo "  To view logs: docker compose -f $COMPOSE_DIR/docker-compose.yml logs -f"
echo "  To recheck:   bash $DOCTOR_SCRIPT"
echo ""
