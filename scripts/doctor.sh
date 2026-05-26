#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SETUP_DIR:-$HOME/.hermes-setup}"
STATE_FILE="$SETUP_DIR/state"
PASS=0
FAIL=0

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
bold()  { echo -e "\033[1m$1\033[0m"; }

check() {
  local desc="$1" status="$2"
  if [[ "$status" == "ok" ]]; then
    green "  ✓ $desc"
    ((++PASS))
  else
    red "  ✗ $desc: $3"
    ((++FAIL))
  fi
}

bold "Hermes Setup – Post-Install Doctor"
echo ""

read_mode() {
  grep "^mode:" "$STATE_FILE" 2>/dev/null | cut -d: -f2
}
MODE="$(read_mode)"
# Read stored ports
OPENWEBUI_PORT=""
if [[ -f "$SETUP_DIR/ow_port" ]]; then
  OPENWEBUI_PORT="$(cat "$SETUP_DIR/ow_port")"
fi
: "${OPENWEBUI_PORT:=3000}"

AIONUI_PORT=""
if [[ -f "$SETUP_DIR/ai_port" ]]; then
  AIONUI_PORT="$(cat "$SETUP_DIR/ai_port")"
fi
: "${AIONUI_PORT:=3000}"

[[ -n "$MODE" ]] && echo "  Mode: $MODE" || echo "  Mode: unknown"
echo ""

# --- Load API key ---
API_SERVER_KEY="${API_SERVER_KEY:-}"
if [[ -z "$API_SERVER_KEY" && -f "$SETUP_DIR/api_key" ]]; then
  API_SERVER_KEY="$(cat "$SETUP_DIR/api_key")"
fi

# ─── Hermes API ────────────────────────────────────────────────────────
echo "--- Hermes API ---"
if [[ -n "$API_SERVER_KEY" ]]; then
  RESPONSE=$(curl -skf -H "Authorization: Bearer $API_SERVER_KEY" http://localhost:8642/v1/models 2>&1) && {
    MODEL_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "?")
    check "Hermes API /v1/models ($MODEL_COUNT models)" "ok"
  } || {
    check "Hermes API /v1/models" "fail" "$RESPONSE"
  }
else
  check "Hermes API /v1/models" "fail" "API_SERVER_KEY not found"
fi

# ─── Hermes CLI ────────────────────────────────────────────────────────
echo ""
echo "--- Hermes CLI ---"
if [[ "$MODE" == "host" && -f "$HOME/.hermes-venv/bin/hermes" ]]; then
  HERMES_VERSION="$("$HOME/.hermes-venv/bin/hermes" --version 2>/dev/null || echo 'unknown')"
  check "Hermes CLI (venv) $HERMES_VERSION" "ok"
elif command -v hermes &>/dev/null; then
  HERMES_VERSION="$(hermes --version 2>/dev/null || echo 'unknown')"
  check "Hermes CLI $HERMES_VERSION" "ok"
else
  check "Hermes CLI" "fail" "not found on PATH"
fi

if [[ "$MODE" == "host" ]]; then
  if systemctl --user is-active hermes-gateway &>/dev/null 2>&1; then
    check "Hermes systemd service" "ok"
  elif [[ -f "$SETUP_DIR/pids/hermes-gateway.pid" ]] && \
       kill -0 "$(cat "$SETUP_DIR/pids/hermes-gateway.pid")" 2>/dev/null; then
    echo "    Hermes gateway running (nohup, PID $(cat "$SETUP_DIR/pids/hermes-gateway.pid"))"
  else
    check "Hermes gateway" "fail" "not running"
  fi
fi

# ─── Open WebUI ────────────────────────────────────────────────────────
echo ""
echo "--- Open WebUI ---"
OW_UP=$(curl -sf "http://localhost:${OPENWEBUI_PORT}/health" 2>&1) && {
  check "Open WebUI /health (port ${OPENWEBUI_PORT})" "ok"
} || {
  check "Open WebUI /health (port ${OPENWEBUI_PORT})" "fail" "$OW_UP"
}

# ─── AionUi ────────────────────────────────────────────────────────────
echo ""
echo "--- AionUi ---"
if [[ "$MODE" == "host" ]]; then
  if pgrep -f 'bun.*server:start' &>/dev/null || pgrep -f 'aionui' &>/dev/null; then
    check "AionUi process" "ok"
  else
    check "AionUi process" "fail" "not running"
  fi
  if timeout 2 bash -c "echo > /dev/tcp/localhost/$AIONUI_PORT" 2>/dev/null; then
    check "AionUi port $AIONUI_PORT" "ok"
  else
    check "AionUi port $AIONUI_PORT" "fail" "not reachable"
  fi
  if [[ -d "$HOME/hermes-aionui" ]]; then
    check "AionUi source dir" "ok"
  else
    check "AionUi source dir" "fail" "not found"
  fi
  # AionUi runtime data dir (info only, not pass/fail)
  if [[ -d "$HOME/.config/AionUi" ]]; then
    echo "    AionUi runtime data: $HOME/.config/AionUi/"
  fi
else
  if timeout 2 bash -c "echo > /dev/tcp/localhost/$AIONUI_PORT" 2>/dev/null; then
    check "AionUi port $AIONUI_PORT" "ok"
  else
    check "AionUi port $AIONUI_PORT" "fail" "not reachable"
  fi
fi

# ─── Port Conflicts ────────────────────────────────────────────────────
echo ""
echo "--- Port Conflicts ---"
for port in 8642 "$OPENWEBUI_PORT" "$AIONUI_PORT"; do
  OWNER=$(ss -tlnpH "sport = :$port" 2>/dev/null | head -1 | awk '{print $6}' || true)
  if [[ -n "$OWNER" ]]; then
    echo "  Port $port: in use by $OWNER"
  fi
done

# ─── Config Integrity ──────────────────────────────────────────────────
echo ""
echo "--- Config Integrity ---"
if [[ -f "$HOME/.hermes/config.yaml" ]]; then
  check "~/.hermes/config.yaml exists" "ok"
  if grep -Fq '${API_SERVER_KEY}' "$HOME/.hermes/config.yaml" 2>/dev/null; then
    check "config.yaml API key format" "fail" "has literal variable (not expanded)"
  fi
else
  check "~/.hermes/config.yaml exists" "fail" "not found"
fi
if [[ -f "$HOME/.hermes/.env" ]]; then
  check "~/.hermes/.env exists" "ok"
else
  check "~/.hermes/.env exists" "fail" "not found"
fi
if [[ "$MODE" == "host" && -d "$HOME/.hermes-venv" ]]; then
  check "~/.hermes-venv exists" "ok"
elif [[ "$MODE" == "host" ]]; then
  check "~/.hermes-venv exists" "fail" "not found"
fi

echo ""
bold "Results: $PASS passed, $FAIL failed"
exit $FAIL
