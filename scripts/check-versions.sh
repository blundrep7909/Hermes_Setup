#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/compose/docker-compose.yml"
SETUP_DIR="${SETUP_DIR:-$HOME/.hermes-setup}"
STATE_FILE="$SETUP_DIR/state"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
info()  { echo -e "  ${GREEN}→${NC} $1"; }
header(){ echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

MODE="$(grep "^mode:" "$STATE_FILE" 2>/dev/null | cut -d: -f2)"
DO_UPDATE=false
[[ "${1:-}" == "--update" ]] && DO_UPDATE=true

D="docker"
DC="docker compose"
if ! docker info &>/dev/null 2>&1; then
  local user="$(whoami)"
  if sudo -u "$user" docker info &>/dev/null 2>&1; then
    D="sudo -u $user docker"
    DC="sudo -u $user docker compose"
  fi
fi

UPDATE_AVAILABLE=false

pull_and_compare() {
  local name="$1" image="$2"
  local current="" latest=""
  
  if ! $D ps --format '{{.Names}}' 2>/dev/null | grep -q "^$name$"; then
    fail "$name: container not running"
    return 1
  fi
  
  current=$($D inspect "$name" --format '{{.Image}}' 2>/dev/null || echo "")
  $D pull "$image" >/dev/null 2>&1
  latest=$($D inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "")
  
  if [[ -z "$current" || -z "$latest" ]]; then
    fail "$name: unable to check version"
    return 1
  fi
  
  if [[ "$current" == "$latest" ]]; then
    ok "$name: up-to-date"
    return 0
  else
    warn "$name: update available"
    UPDATE_AVAILABLE=true
    return 2
  fi
}

header "Version Check${MODE:+ — $MODE mode}"
echo ""

if [[ -z "$MODE" ]]; then
  fail "No installation detected (state file not found)"
  exit 1
fi

# ─── Hermes Agent ──────────────────────────────────────────────────────
hermes_image=$($D inspect hermes --format '{{.Config.Image}}' 2>/dev/null || echo "ghcr.io/anomalyco/hermes-agent:0.14.11")
hermes_image="${hermes_image:-ghcr.io/anomalyco/hermes-agent:0.14.11}"
pull_and_compare "hermes" "$hermes_image" || true

# ─── Open WebUI ───────────────────────────────────────────────────────
pull_and_compare "open-webui" "ghcr.io/open-webui/open-webui:latest" || true

# ─── AionUi ───────────────────────────────────────────────────────────
if $D ps --format '{{.Names}}' 2>/dev/null | grep -q '^aionui$'; then
  created=$($D inspect aionui --format '{{.Created}}' 2>/dev/null | cut -d. -f1)
  ok "AionUi: container running (built $created)"
else
  fail "AionUi: container not running"
fi

# ─── 9Router ─────────────────────────────────────────────────────────
pull_and_compare "9router" "decolua/9router:latest" || true

# ─── OpenCode ─────────────────────────────────────────────────────────
echo ""
echo "--- OpenCode CLI ---"
if command -v opencode &>/dev/null; then
  ver=$(opencode --version 2>/dev/null || echo "installed")
  ok "OpenCode CLI: $ver"
else
  fail "OpenCode CLI: not installed"
fi

# ─── Summary ──────────────────────────────────────────────────────────
echo ""
if [[ "$UPDATE_AVAILABLE" == "true" ]]; then
  warn "Some components have updates available"
  echo ""
  if [[ "$DO_UPDATE" == "true" ]]; then
    info "Running update..."
    bash "$SCRIPT_DIR/update.sh" "--${MODE:-docker}"
  else
    echo "  Run: bash check-versions.sh --update"
    echo "  Or:  bash $SCRIPT_DIR/update.sh --${MODE:-docker}"
  fi
else
  ok "All components up-to-date"
fi
