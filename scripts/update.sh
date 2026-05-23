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

header "Update — $MODE mode"

if [[ "$MODE" == "host" ]]; then
  # ─── Hermes ──────────────────────────────────────────────────────────
  if [[ -d "$HOME/.hermes-venv" ]]; then
    info "Updating Hermes via pip..."
    "$HOME/.hermes-venv/bin/pip" install --upgrade hermes-agent[acp] 2>/dev/null || \
      warn "pip upgrade failed, skipping Hermes update"

    if systemctl --user is-active hermes-gateway &>/dev/null 2>&1; then
      info "Restarting Hermes gateway..."
      systemctl --user restart hermes-gateway
    elif [[ -f "$SETUP_DIR/pids/hermes-gateway.pid" ]]; then
      info "Restarting Hermes gateway (nohup)..."
      kill "$(cat "$SETUP_DIR/pids/hermes-gateway.pid")" 2>/dev/null || true
      nohup "$SETUP_DIR/hermes-start.sh" > "$HOME/.hermes/hermes-gateway.log" 2>&1 &
      echo $! > "$SETUP_DIR/pids/hermes-gateway.pid"
    fi
  else
    warn "Hermes venv not found at ~/.hermes-venv — skipping Hermes update"
  fi

  # ─── AionUi ──────────────────────────────────────────────────────────
  AIONUI_DIR="$HOME/hermes-aionui"
  if [[ -d "$AIONUI_DIR" ]]; then
    BUN_BIN=""
    for b in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun" "$(command -v bun 2>/dev/null)"; do
      if [[ -x "$b" ]]; then BUN_BIN="$b"; break; fi
    done
    if [[ -n "$BUN_BIN" ]]; then
      info "Updating AionUi source..."
      git -C "$AIONUI_DIR" pull --ff-only 2>/dev/null || warn "git pull failed, skipping AionUi update"
      info "Rebuilding AionUi..."
      "$BUN_BIN" install --cwd "$AIONUI_DIR"
      "$BUN_BIN" run --cwd "$AIONUI_DIR" build

      if systemctl --user is-active aionui-webui &>/dev/null 2>&1; then
        info "Restarting AionUi..."
        systemctl --user restart aionui-webui
      elif [[ -f "$SETUP_DIR/pids/aionui-webui.pid" ]]; then
        info "Restarting AionUi (nohup)..."
        kill "$(cat "$SETUP_DIR/pids/aionui-webui.pid")" 2>/dev/null || true
        nohup "$SETUP_DIR/aionui-start.sh" > "$HOME/hermes-aionui/aionui-webui.log" 2>&1 &
        echo $! > "$SETUP_DIR/pids/aionui-webui.pid"
      fi
    else
      warn "bun not found — skipping AionUi update"
    fi
  else
    warn "AionUi directory not found at $AIONUI_DIR — skipping"
  fi

  # ─── Open WebUI (Docker) ─────────────────────────────────────────────
  info "Pulling latest Open WebUI image..."
  docker pull ghcr.io/open-webui/open-webui:0.9.17
  if docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
    info "Recreating Open WebUI container..."
    docker stop open-webui && docker rm open-webui
    docker run -d \
      --name open-webui \
      --restart unless-stopped \
      -p 3000:8080 \
      --add-host host.docker.internal:host-gateway \
      -v open-webui-data:/app/backend/data \
      -e "OPENAI_API_BASE_URL=http://host.docker.internal:8642/v1" \
      -e "OPENAI_API_KEY=$(grep '^API_SERVER_KEY=' "$HOME/.hermes/.env" 2>/dev/null | head -1 | cut -d= -f2 || echo '')" \
      -e BYPASS_MODEL_ACCESS_CONTROL=true \
      -e AIOHTTP_CLIENT_TIMEOUT=120 \
      ghcr.io/open-webui/open-webui:0.9.17
  fi
else
  # ─── Docker Mode ─────────────────────────────────────────────────────
  info "Pulling latest Docker images..."
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
fi

info "Running post-update verification..."
bash "$SCRIPT_DIR/doctor.sh" || true

header "Update complete"
echo ""
echo "  Run bash $SCRIPT_DIR/doctor.sh to recheck anytime."
echo ""
