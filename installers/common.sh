#!/usr/bin/env bash
# Hermes Setup – Shared Functions
# Source this file from host.sh or docker.sh:  source "$(dirname "$0")/common.sh"
set -euo pipefail

SETUP_DIR="${SETUP_DIR:-$HOME/.hermes-setup}"
HERMES_CONFIG_DIR="$HOME/.hermes"
HERMES_CONFIG="$HERMES_CONFIG_DIR/config.yaml"
HERMES_ENV="$HERMES_CONFIG_DIR/.env"
STATE_FILE="$SETUP_DIR/state"
API_KEY_FILE="$SETUP_DIR/api_key"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../compose" && pwd)"
DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
DOCTOR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/doctor.sh"

# ─── Colors ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ─── Safety Guards ─────────────────────────────────────────────────────
validate_home() {
  if [[ -z "${HOME:-}" || "$HOME" == "/" ]]; then
    error "HOME is not set or is root. This script must run as a normal user."
    exit 1
  fi
}

check_disk_space() {
  local needed_mb="${1:-3500}"
  local available_kb
  available_kb="$(df --output=avail "$HOME" 2>/dev/null | tail -1)" || available_kb=0
  local available_mb=$((available_kb / 1024))
  if [[ $available_mb -lt $needed_mb ]]; then
    warn "Low disk space: ${available_mb}MB available, ~${needed_mb}MB recommended"
    read -rp "Continue anyway? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then exit 1; fi
  fi
}

# ─── OS / Platform Detection ──────────────────────────────────────────
detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "linux"
  fi
}

detect_wsl() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl2"
  elif [[ "$(uname -r)" =~ [Mm]icrosoft|[Ww][Ss][Ll] ]]; then
    echo "wsl2"
  else
    echo "native"
  fi
}

# ─── Systemd Detection ────────────────────────────────────────────────
SYSTEMD_AVAILABLE=false

check_systemd() {
  if ! command -v systemctl &>/dev/null; then
    warn "systemctl not found — systemd not available"
    return 1
  fi
  if ! systemctl --user list-units --quiet &>/dev/null 2>&1; then
    warn "Systemd user instance not running"
    warn "  Installer will use nohup fallback instead of systemd services"
    return 1
  fi
  SYSTEMD_AVAILABLE=true
  info "Systemd user instance detected — using systemd services"
}

# ─── Privilege Escalation ─────────────────────────────────────────────
sudo_check() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
      SUDO="sudo"
    else
      error "This step requires root privileges. Please run with sudo or as root."
      exit 1
    fi
  else
    SUDO=""
  fi
}

# ─── Docker + Compose Verification ────────────────────────────────────
D="docker"
DC="docker compose"
check_docker() {
  if ! command -v docker &>/dev/null; then
    error "Docker not found. Install Docker first: https://docs.docker.com/engine/install/"
    exit 1
  fi

  # Check if user needs sudo for docker commands
  if ! docker info &>/dev/null; then
    local user="$(whoami)"
    if sudo -u "$user" docker info &>/dev/null 2>&1; then
      D="sudo -u $user docker"
      DC="sudo -u $user docker compose"
      warn "Permission denied — using sudo -u $user for docker commands"
    elif sudo -n docker info &>/dev/null 2>&1; then
      D="sudo -n docker"
      DC="sudo -n docker compose"
      warn "Permission denied — using sudo -n for docker commands"
    else
      error "Docker daemon is not running or permission denied."
      error "  Add yourself to the docker group: sudo usermod -aG docker $USER && newgrp docker"
      error "  Then start Docker: sudo systemctl start docker"
      exit 1
    fi
  fi

  if ! $DC version &>/dev/null; then
    error "Docker Compose v2 not found. Upgrade Docker: https://docs.docker.com/compose/install/"
    exit 1
  fi
  info "Docker $($D --version | cut -d' ' -f3 | tr -d ',')"
  info "Compose $($DC version | cut -d' ' -f4)"

  # Check if host-gateway is supported (Docker >= 20.10)
  if ! $D info --format '{{.ServerVersion}}' 2>/dev/null | grep -q '^2[0-9]\.'; then
    warn "Docker < 20.10 detected — host.docker.internal may not resolve automatically"
  fi
}

# ─── Port Availability ────────────────────────────────────────────────
port_check() {
  local port="$1" name="$2"
  if timeout 2 bash -c "echo > /dev/tcp/0.0.0.0/$port" 2>/dev/null; then
    warn "Port $port ($name) is already in use"
    return 1
  fi
  info "Port $port ($name): available"
}

preflight_port_check() {
  local any_busy=false
  for spec in 8642:Hermes 3000:OpenWebUI 3001:AionUi; do
    local port="${spec%%:*}"
    local name="${spec##*:}"
    if timeout 2 bash -c "echo > /dev/tcp/0.0.0.0/$port" 2>/dev/null; then
      local owner=""
      if command -v ss &>/dev/null; then
        owner=$(ss -tlnpH "sport = :$port" 2>/dev/null | head -1 | sed 's/.*users:(("//;s/".*//')
      elif command -v lsof &>/dev/null; then
        owner=$(lsof -i :$port -sTCP:LISTEN 2>/dev/null | tail -1 | awk '{print $1}')
      fi
      if [[ -n "$owner" ]]; then
        error "Port $port ($name) in use by: $owner"
      else
        error "Port $port ($name) already in use"
      fi
      any_busy=true
    fi
  done
  if [[ "$any_busy" == "true" ]]; then
    echo ""
    info "Port conflict — installation blocked."
    info "  To free a port: kill the process or change the port assignment."
    info "  Example: sudo lsof -i :3000  →  kill <PID>"
    exit 1
  fi
  info "All required ports (8642, 3000, 3001): available"
}

# ─── API Key Generation ──────────────────────────────────────────────
generate_key() {
  mkdir -p "$SETUP_DIR"
  if [[ -f "$API_KEY_FILE" ]]; then
    API_SERVER_KEY="$(cat "$API_KEY_FILE")"
    info "Using existing API key from $API_KEY_FILE"
  else
    API_SERVER_KEY="$(openssl rand -hex 16 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(16))")"
    echo "$API_SERVER_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    info "Generated new API key"
  fi
  export API_SERVER_KEY
}

# ─── Hermes Config (fix #10: backup before overwrite) ─────────────────
ensure_hermes_config() {
  mkdir -p "$HERMES_CONFIG_DIR"
  if [[ -f "$HERMES_CONFIG" ]]; then
    if grep -Fq '${API_SERVER_KEY}' "$HERMES_CONFIG" 2>/dev/null; then
      cp "$HERMES_CONFIG" "$HERMES_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
      warn "Backed up old buggy config, overwriting with live API key"
    else
      info "Hermes config already exists at $HERMES_CONFIG (not overwriting)"
      return 0
    fi
  fi
  cat > "$HERMES_CONFIG" <<HERMES_CONFIG_EOF
api_server:
  enabled: true
  key: ${API_SERVER_KEY}
  port: 8642

providers: []

auxiliary:
  compression:
    timeout: 300
HERMES_CONFIG_EOF
  chmod 600 "$HERMES_CONFIG"
  info "Created $HERMES_CONFIG with live API key"
}

ensure_hermes_env() {
  mkdir -p "$HERMES_CONFIG_DIR"
  if [[ -f "$HERMES_ENV" ]] && grep -q "API_SERVER_KEY" "$HERMES_ENV" 2>/dev/null; then
    info "Hermes .env already exists at $HERMES_ENV (not overwriting)"
    return 0
  fi
  cat > "$HERMES_ENV" <<HERMES_ENV_EOF
API_SERVER_ENABLED=true
API_SERVER_KEY=${API_SERVER_KEY}
HERMES_ENV_EOF
  chmod 600 "$HERMES_ENV"
  info "Created $HERMES_ENV"
}

# ─── URL Validation ───────────────────────────────────────────────────
validate_url() {
  local url="$1"
  url="${url%/}"
  if [[ "$url" != */v1 ]] && [[ "$url" != */v1/ ]]; then
    url="${url}/v1"
  fi
  echo "$url"
}

# ─── Mode Persistence ────────────────────────────────────────────────
store_mode() {
  mkdir -p "$SETUP_DIR"
  local mode="${1:-unknown}"
  if [[ -f "$STATE_FILE" ]] && grep -q "^mode:" "$STATE_FILE" 2>/dev/null; then
    sed -i "s/^mode:.*/mode:${mode}/" "$STATE_FILE"
  else
    echo "mode:${mode}" >> "$STATE_FILE"
  fi
  info "Installation mode saved: $mode"
}

read_mode() {
  grep "^mode:" "$STATE_FILE" 2>/dev/null | cut -d: -f2
}

# ─── Rollback (fix #17: add disable-linger) ────────────────────────────
rollback_init() {
  mkdir -p "$SETUP_DIR"
  : > "$STATE_FILE"
  trap rollback_cleanup EXIT
}

rollback_step() {
  echo "$*" >> "$STATE_FILE"
}

rollback_cleanup() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    trap - EXIT
    return 0
  fi
  error "Installation failed at step: $(tail -1 "$STATE_FILE" 2>/dev/null || echo 'unknown')"
  if [[ -f "$STATE_FILE" ]]; then
    while IFS= read -r step; do
      case "$step" in
        "linger_enabled")
          warn "Rolling back: disabling systemd linger"
          sudo loginctl disable-linger "$(whoami)" 2>/dev/null || true
          ;;
        "compose_up")
          warn "Rolling back: docker compose down"
          $DC -f "$COMPOSE_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null || true
          ;;
        "docker_run")
          warn "Rolling back: stopping open-webui container"
          $D stop open-webui 2>/dev/null || true
          $D rm open-webui 2>/dev/null || true
          ;;
        "systemd_hermes")
          warn "Rolling back: disabling hermes-gateway service"
          systemctl --user disable --now hermes-gateway 2>/dev/null || true
          rm -f "$HOME/.config/systemd/user/hermes-gateway.service"
          ;;
        "systemd_aionui")
          warn "Rolling back: disabling aionui-webui service"
          systemctl --user disable --now aionui-webui 2>/dev/null || true
          rm -f "$HOME/.config/systemd/user/aionui-webui.service"
          ;;
        "aionui_build")
          warn "Rolling back: removing AionUi build"
          rm -rf "$HOME/hermes-aionui" 2>/dev/null || true
          ;;
        "nohup_start")
          warn "Rolling back: killing nohup processes"
          if [[ -f "$HOME/.hermes-setup/pids/hermes-gateway.pid" ]]; then
            kill "$(cat "$HOME/.hermes-setup/pids/hermes-gateway.pid")" 2>/dev/null || true
          fi
          if [[ -f "$HOME/.hermes-setup/pids/aionui-webui.pid" ]]; then
            kill "$(cat "$HOME/.hermes-setup/pids/aionui-webui.pid")" 2>/dev/null || true
          fi
          rm -rf "$HOME/.hermes-setup/pids" 2>/dev/null || true
          ;;
        "venv_created")
          warn "Rolling back: removing Hermes venv"
          rm -rf "$HOME/.hermes-venv" 2>/dev/null || true
          ;;
        "pip_install")
          warn "Rolling back: removing Hermes venv"
          rm -rf "$HOME/.hermes-venv" 2>/dev/null || true
          ;;
        "config_written")
          warn "Rolling back: removing config files"
          rm -f "$HERMES_ENV" "$HERMES_CONFIG" 2>/dev/null || true
          ;;
      esac
    done < "$STATE_FILE"
    rm -f "$STATE_FILE"
  fi
  error "Installation aborted. Run again after fixing the issue."
}

# ─── Version Pinning ──────────────────────────────────────────────────
HERMES_IMAGE="ghcr.io/anomalyco/hermes-agent:0.14.11"
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"
