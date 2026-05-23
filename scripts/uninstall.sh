#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/compose/docker-compose.yml"
SETUP_DIR="${SETUP_DIR:-$HOME/.hermes-setup}"
STATE_FILE="$SETUP_DIR/state"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ─── Safety: HOME guard ───────────────────────────────────────────────
if [[ -z "${HOME:-}" || "$HOME" == "/" ]]; then
  error "HOME is not set or is root. Aborting."
  exit 1
fi

# ─── Docker Permission Setup (same as installer) ─────────────────────────
D="docker"
DC="docker compose"
check_docker_uninstall() {
  if command -v docker &>/dev/null; then
    if ! docker info &>/dev/null 2>&1; then
      local user="$(whoami)"
      if sudo -u "$user" docker info &>/dev/null 2>&1; then
        D="sudo -u $user docker"
        DC="sudo -u $user docker compose"
      fi
    fi
  fi
}
check_docker_uninstall || true

read_mode() {
  grep "^mode:" "$STATE_FILE" 2>/dev/null | cut -d: -f2
}

MODE="${1:-}"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --host)   MODE="host"   ;;
    --docker) MODE="docker" ;;
    --force)  FORCE=true    ;;
  esac
done

if [[ -z "$MODE" ]]; then
  MODE="$(read_mode)"
fi

case "$MODE" in
  host|docker) ;;
  *)
    error "Cannot detect installation mode."
    echo "Usage: bash $0 [--host | --docker] [--force]"
    exit 1
    ;;
esac

header "Uninstall — $MODE mode"
warn "This will remove Hermes Stack components and optionally all data."
echo ""

# ─── Confirmation ──────────────────────────────────────────────────
if [[ "$FORCE" != "true" ]]; then
  read -rp "Stop services and remove config files? [y/N] " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
  fi

  echo ""
  echo "  Data that will be removed if you choose YES:"
  echo "    • Docker volumes (open-webui-data, aionui-data) — all chat history"
  echo "    • ~/.hermes/ — provider config, sessions, memory, skills"
  echo "    • ~/hermes-aionui/ — AionUi source + node_modules"
  echo "    • ~/.config/AionUi/ — AionUi runtime data"
  echo "    • ~/.bun/ — Bun runtime (only if installed by Hermes Setup)"
  echo ""
  read -rp "Also DELETE ALL DATA? [y/N] " REPLY
  DELETE_DATA=false
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    DELETE_DATA=true
    warn "DATA WILL BE DELETED. Last chance — Ctrl+C now to abort."
    sleep 3
  fi
else
  DELETE_DATA=true
fi

# ─── Stop Services (host mode) ─────────────────────────────────────
if [[ "$MODE" == "host" ]]; then
  header "Stopping services"
  if command -v systemctl &>/dev/null && systemctl --user list-units --quiet &>/dev/null 2>&1; then
    for svc in aionui-webui hermes-gateway; do
      if systemctl --user is-active "$svc" &>/dev/null 2>&1; then
        systemctl --user disable --now "$svc" 2>/dev/null || true
        info "Stopped $svc (systemd)"
      fi
    done
    rm -f "$HOME/.config/systemd/user/hermes-gateway.service" \
          "$HOME/.config/systemd/user/aionui-webui.service" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  # Kill nohup processes via PID file (whether systemd was used or not)
  for pid_file in "$SETUP_DIR/pids/hermes-gateway.pid" "$SETUP_DIR/pids/aionui-webui.pid"; do
    if [[ -f "$pid_file" ]]; then
      kill "$(cat "$pid_file")" 2>/dev/null || true
      rm -f "$pid_file"
      info "Killed nohup process ($(basename "$pid_file" .pid))"
    fi
  done
else
  header "Stopping containers"
  if $DC -f "$COMPOSE_FILE" ps --services --filter "status=running" 2>/dev/null | grep -q .; then
    $DC -f "$COMPOSE_FILE" down --remove-orphans
    info "Containers stopped and removed."
  else
    info "No running containers found."
  fi
fi

# ─── Remove Open WebUI container (both modes) ──────────────────────
if $D ps -a --format '{{.Names}}' | grep -q '^open-webui$' 2>/dev/null; then
  $D stop open-webui 2>/dev/null || true
  $D rm open-webui 2>/dev/null || true
  info "Open WebUI container removed."
fi

# ─── Remove Volumes / Data ─────────────────────────────────────────
if [[ "$DELETE_DATA" == "true" ]]; then
  header "Removing data"

  for vol in open-webui-data aionui-data; do
    if $D volume inspect "$vol" &>/dev/null 2>&1; then
      $D volume rm "$vol" >/dev/null 2>&1 || true
      info "Docker volume $vol removed."
    fi
  done

  # Remove Docker images
  $D rmi ghcr.io/anomalyco/hermes-agent:0.14.11 2>/dev/null || true
  $D rmi ghcr.io/open-webui/open-webui:latest 2>/dev/null || true
  $D rmi hermes-setup-aionui 2>/dev/null || true

  # Hermes config
  if [[ -d "$HOME/.hermes" ]]; then
    rm -rf "$HOME/.hermes"
    info "~/.hermes/ removed."
  fi

  # AionUi runtime data (fix #6)
  rm -rf "$HOME/.config/AionUi" 2>/dev/null || true

  # Bun runtime — only if we installed it (fix #5)
  if [[ ! -f "$SETUP_DIR/bun_pre_existing" ]]; then
    rm -rf "$HOME/.bun" 2>/dev/null || true
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
      [[ -f "$rc" ]] && sed -i '/[Bb]un/d' "$rc" 2>/dev/null || true
    done
  fi
fi

# ─── Hermes venv (host mode) ───────────────────────────────────────
if [[ "$MODE" == "host" ]]; then
  if [[ -d "$HOME/.hermes-venv" ]]; then
    rm -rf "$HOME/.hermes-venv"
    info "Hermes venv ~/.hermes-venv removed."
  fi

  if [[ -d "$HOME/hermes-aionui" ]]; then
    rm -rf "$HOME/hermes-aionui"
    info "AionUi source ~/hermes-aionui removed."
  fi

  # Fix #4: remove symlink
  rm -f "$HOME/.local/bin/hermes" 2>/dev/null || true

  # Fix #3: marker-based shell rc cleanup (safe block removal)
  RC_MARKER_START="# --- Hermes Setup (auto-generated, do not edit) ---"
  RC_MARKER_END="# --- /Hermes Setup ---"
  for rc_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [[ -f "$rc_file" ]]; then
      sed -i "/^${RC_MARKER_START}$/,/^${RC_MARKER_END}$/d" "$rc_file" 2>/dev/null || true
      # Clean up any leftover blank lines from deletion
      sed -i '/^$/N;/^\n$/D' "$rc_file" 2>/dev/null || true
    fi
  done
fi

# ─── Revert systemd linger (fix #1) ─────────────────────────────────
if command -v loginctl &>/dev/null; then
  if sudo loginctl show-user "$(whoami)" 2>/dev/null | grep -q "Linger=yes"; then
    sudo loginctl disable-linger "$(whoami)" 2>/dev/null || true
    info "Systemd linger disabled (reverted system-level change)."
  fi
fi

# ─── Setup metadata (must be deleted LAST — before zero-residue check) ──
rm -rf "$SETUP_DIR"

# ─── Zero-Residue Verification (fix #7) ──────────────────────────────
header "Verifying clean uninstall"
RESIDUE=false

check_residue() {
  local path="$1" label="$2"
  if [[ -e "$path" ]]; then
    warn "  LEFTOVER: $label ($path)"
    RESIDUE=true
  fi
}

check_residue "$HOME/.hermes" "Hermes config"
check_residue "$HOME/.hermes-venv" "Hermes venv"
check_residue "$HOME/hermes-aionui" "AionUi source"
check_residue "$HOME/.hermes-setup" "Setup metadata"
check_residue "$HOME/.local/bin/hermes" "Hermes symlink"
check_residue "$HOME/.config/AionUi" "AionUi runtime data"
check_residue "$HOME/.config/systemd/user/hermes-gateway.service" "Systemd unit (hermes)"
check_residue "$HOME/.config/systemd/user/aionui-webui.service" "Systemd unit (aionui)"

if $D ps -a --format '{{.Names}}' | grep -q '^open-webui$' 2>/dev/null; then
  warn "  LEFTOVER: Open WebUI container"
  RESIDUE=true
fi

if [[ "$RESIDUE" == "false" ]]; then
  info "Zero residue — no Hermes Stack files remain on this system."
fi

echo ""
header "Uninstall complete"
echo ""
echo "  To remove the repo itself: rm -rf $(git rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")"
echo ""
