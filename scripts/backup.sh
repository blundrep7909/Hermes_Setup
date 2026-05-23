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

BACKUP_DIR="${BACKUP_DIR:-$HOME/hermes-backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/hermes-backup-$TIMESTAMP"

read_mode() {
  grep "^mode:" "$STATE_FILE" 2>/dev/null | cut -d: -f2
}

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  MODE="$(read_mode)"
fi

case "$MODE" in
  --host|host)  MODE="host"  ;;
  --docker|docker) MODE="docker" ;;
  *)
    error "Cannot detect installation mode."
    echo "Usage: bash $0 [--host | --docker]"
    exit 1
    ;;
esac

header "Backup — $MODE mode"
mkdir -p "$BACKUP_PATH"
info "Backup destination: $BACKUP_PATH"

# ─── Hermes config (always backed up) ────────────────────────────────
if [[ -d "$HOME/.hermes" ]]; then
  info "Backing up ~/.hermes/..."
  tar czf "$BACKUP_PATH/hermes-config.tar.gz" -C "$HOME" .hermes
fi

# ─── Hermes venv + setup metadata ────────────────────────────────────
if [[ -d "$SETUP_DIR" ]]; then
  info "Backing up setup metadata..."
  tar czf "$BACKUP_PATH/hermes-setup-meta.tar.gz" -C "$(dirname "$SETUP_DIR")" "$(basename "$SETUP_DIR")"
fi

# ─── Docker volumes (shared + host-specific) ─────────────────────────
backup_volume() {
  local vol="$1" label="$2"
  if docker volume inspect "$vol" &>/dev/null 2>&1; then
    info "Backing up Docker volume: $label ($vol)..."
    docker run --rm \
      -v "${vol}:/source:ro" \
      -v "${BACKUP_PATH}:/backup" \
      alpine tar czf "/backup/${vol}.tar.gz" -C /source . 2>/dev/null && \
    info "  → $BACKUP_PATH/${vol}.tar.gz"
  else
    warn "Volume $vol not found, skipping"
  fi
}

if [[ "$MODE" == "docker" ]]; then
  backup_volume "open-webui-data" "Open WebUI"
  backup_volume "aionui-data" "AionUi"
else
  backup_volume "open-webui-data" "Open WebUI"

  # ─── AionUi source dir (host mode) ──────────────────────────────────
  if [[ -d "$HOME/hermes-aionui" ]]; then
    info "Backing up AionUi source directory... (config only, not node_modules)"
    tar czf "$BACKUP_PATH/aionui-source.tar.gz" \
      --exclude='node_modules' \
      --exclude='.git' \
      -C "$HOME" hermes-aionui 2>/dev/null || warn "AionUi backup incomplete"
  fi

  # ─── Hermes venv ────────────────────────────────────────────────────
  if [[ -d "$HOME/.hermes-venv" ]]; then
    info "Backing up Hermes venv pip list..."
    "$HOME/.hermes-venv/bin/pip" freeze > "$BACKUP_PATH/hermes-venv-packages.txt" 2>/dev/null
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────
header "Backup complete"
echo "  Location: $BACKUP_PATH"
echo "  Contents:"
ls -lh "$BACKUP_PATH" | awk '{print "    " $NF " (" $5 ")"}'
echo ""
echo "  To restore:"
echo "    1. Reinstall: bash installers/$MODE.sh"
echo "    2. Extract archives: tar xzf ... -C ~"
echo "    3. Restore Docker volumes as needed"
echo ""
