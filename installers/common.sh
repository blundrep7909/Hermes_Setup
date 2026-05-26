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

install_docker() {
  local os
  os="$(detect_os)"

  info "Installing Docker for OS: $os..."

  case "$os" in
    ubuntu|debian|linuxmint|pop|elementary|zorin)
      info "Detected Debian/Ubuntu — installing Docker via apt..."
      sudo apt-get update -qq
      sudo apt-get install -y -qq ca-certificates curl gnupg
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update -qq
      sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    fedora|centos|rhel|rocky|almalinux)
      info "Detected RHEL/Fedora — installing Docker via dnf..."
      sudo dnf -y install dnf-plugins-core
      sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    arch|manjaro|endeavouros)
      info "Detected Arch — installing Docker via pacman..."
      sudo pacman -Sy --noconfirm docker docker-compose
      ;;
    opensuse*|suse)
      info "Detected SUSE — installing Docker via zypper..."
      sudo zypper -n install docker docker-compose
      ;;
    *)
      info "Using Docker official convenience script..."
      curl -fsSL https://get.docker.com | sudo sh
      ;;
  esac

  sudo groupadd -f docker 2>/dev/null || true
  sudo usermod -aG docker "$(whoami)" 2>/dev/null || true

  if command -v systemctl &>/dev/null; then
    sudo systemctl enable docker 2>/dev/null || true
    sudo systemctl start docker 2>/dev/null || true
  elif command -v service &>/dev/null; then
    sudo service docker start 2>/dev/null || true
  fi

  info "Docker installed."
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    info "Docker not found — installing automatically..."
    install_docker
  fi

  if ! command -v docker &>/dev/null; then
    error "Docker installation failed. Install manually: https://docs.docker.com/engine/install/"
    exit 1
  fi

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
      error "  Try: newgrp docker || sudo service docker start || sudo systemctl start docker"
      exit 1
    fi
  fi

  if ! $DC version &>/dev/null; then
    error "Docker Compose v2 not found. Upgrade Docker: https://docs.docker.com/compose/install/"
    exit 1
  fi
  info "Docker $($D --version | cut -d' ' -f3 | tr -d ',')"
  info "Compose $($DC version | cut -d' ' -f4)"

  if ! $D info --format '{{.ServerVersion}}' 2>/dev/null | grep -q '^2[0-9]\.'; then
    warn "Docker < 20.10 detected — host.docker.internal may not resolve automatically"
  fi
}

# ─── Docker Port Canary ───────────────────────────────────────────────
docker_port_canary() {
  local port="$1"
  [[ -z "${D:-}" ]] && return 0
  local img="alpine:3.19"
  $D image inspect "$img" &>/dev/null || $D pull "$img" &>/dev/null || return 0
  $D run --rm -p "$port":8080 "$img" true 2>/dev/null
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

port_owner() {
  local port="$1"
  local owner=""
  if command -v ss &>/dev/null; then
    owner=$(ss -tlnpH "sport = :$port" 2>/dev/null | head -1 | sed 's/.*users:(("//;s/".*//')
    if [[ -z "$owner" ]] && sudo -n ss -tlnpH "sport = :$port" 2>/dev/null | head -1 | sed 's/.*users:(("//;s/".*//' 2>/dev/null; then
      owner=$(sudo -n ss -tlnpH "sport = :$port" 2>/dev/null | head -1 | sed 's/.*users:(("//;s/".*//')
    fi
  elif command -v lsof &>/dev/null; then
    owner=$(lsof -i :$port -sTCP:LISTEN 2>/dev/null | tail -1 | awk '{print $1}')
    [[ -z "$owner" ]] && owner=$(sudo -n lsof -i :$port -sTCP:LISTEN 2>/dev/null | tail -1 | awk '{print $1}')
  fi
  echo "$owner"
}

# ─── Existing Installation Detection ──────────────────────────────────
is_component_installed() {
  case "${1,,}" in
    hermes)
      [[ -f "$HOME/.hermes/config.yaml" ]] || [[ -d "$HOME/.hermes-venv" ]]
      ;;
    openwebui)
      if command -v docker &>/dev/null; then
        if [[ -n "${D:-}" ]]; then
          $D ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'
        else
          docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$' || \
          sudo -n docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'
        fi
      fi
      ;;
    aionui)
      [[ -d "$HOME/hermes-aionui" ]]
      ;;
    *) return 1 ;;
  esac
}

detect_existing_installation() {
  local found=""
  is_component_installed "Hermes"    && found="$found hermes"
  is_component_installed "OpenWebUI" && found="$found openwebui"
  is_component_installed "AionUi"    && found="$found aionui"
  echo "$found"
}

prompt_install_mode() {
  local detected="$1"

  header "Existing Installation Detected" >&2
  echo "" >&2
  echo "  Components found:$detected" >&2
  echo "" >&2
  echo "  (U)pdate   — upgrade existing + install missing (default)" >&2
  echo "  (F)resh    — wipe everything, then clean install" >&2
  echo "  (C)ancel   — do nothing" >&2
  echo "" >&2

  if [[ "${UPDATE_FLAG:-false}" == "true" ]]; then
    echo "update"
  elif [[ "${FRESH_FLAG:-false}" == "true" ]]; then
    echo "fresh"
  elif [[ -t 0 ]]; then
    local REPLY
    while true; do
      read -rp "  Choose [U/f/c]: " REPLY >&2
      REPLY="${REPLY:-U}"
      case "${REPLY^^}" in
        U) echo "update"; return 0 ;;
        F) echo "fresh";  return 0 ;;
        C) echo "cancel"; return 0 ;;
      esac
      echo "  Invalid — enter U, F, or C" >&2
    done
  else
    echo "update"
  fi
}

# ─── Find next available port ─────────────────────────────────────
find_available_port() {
  local base="${1:-3000}" max="${2:-3010}"
  local d_cmd="${D:-docker}"
  for port in $(seq "$base" "$max"); do
    if timeout 1 bash -c "echo > /dev/tcp/0.0.0.0/$port" 2>/dev/null; then
      continue
    fi
    if command -v docker &>/dev/null; then
      if ! $d_cmd run --rm -p "${port}:8080" alpine:3.19 true 2>/dev/null; then
        continue
      fi
    fi
    echo "$port"; return 0
  done
  echo "$base"; return 1
}

# ─── Port Preflight ─────────────────────────────────────────────────
preflight_port_check() {
  local mode="${1:-docker}"
  local any_busy=false any_ours=false
  # Only check Hermes API port (8642) — other ports are auto-assigned
  ports="8642:Hermes"
  for spec in $ports; do
    local port="${spec%%:*}"
    local name="${spec##*:}"

    if timeout 2 bash -c "echo > /dev/tcp/0.0.0.0/$port" 2>/dev/null; then
      if is_component_installed "$name"; then
        warn "Port $port ($name) in use by existing $name installation"
        any_ours=true
      else
        local owner; owner=$(port_owner "$port")
        if [[ -n "$owner" ]]; then
          warn "Port $port ($name) in use by: $owner — will auto-assign a different port"
        else
          warn "Port $port ($name) already in use — will auto-assign a different port"
        fi
      fi

    elif [[ "$port" == "3000" ]] && [[ -n "${D:-}" ]]; then
      if ! docker_port_canary "$port"; then
        if is_component_installed "OpenWebUI"; then
          warn "Port $port ($name) Docker port busy — existing Open WebUI installation"
          any_ours=true
        else
          error "Port $port ($name) is busy inside Docker — restart Docker or kill dangling docker-proxy"
          any_busy=true
        fi
      fi
    fi
  done
  if [[ "$any_busy" == "true" ]]; then
    echo ""
    warn "Some ports were busy — auto-assigning available ports."
  fi
  if [[ "$any_ours" == "true" ]]; then
    echo ""
    warn "Existing Hermes Stack components detected on required ports."
  else
    info "All required ports: 8642, 3000, 3001"
  fi
}

# ─── Open WebUI Container Start (shared by host.sh & docker.sh) ──────
start_openwebui_container() {
  local openwebui_url="$1"
  local api_key="$2"
  local host_port="${3:-3000}"

  if $D ps --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
    info "Open WebUI container already running"
    return 0
  fi

  $D rm -f open-webui >/dev/null 2>&1 || true

  # Wait for port 3000 to be Docker-bindable (Docker canary — works in WSL2)
  info "Waiting for port ${host_port} to be available..."
  for i in $(seq 1 30); do
    if $D run --rm -p "${host_port}:8080" alpine:3.19 true 2>/dev/null; then
      info "Port ${host_port} is now available."
      break
    fi
    if [[ $i -eq 30 ]]; then
      error "Port ${host_port} still busy after 90s — try: sudo service docker restart"
      exit 125
    fi
    printf "."
    sleep 3
  done
  echo "" # to end the line of dots

  info "Pulling Open WebUI image ($OPENWEBUI_IMAGE)..."
  $D pull "$OPENWEBUI_IMAGE" 2>&1 || true

  info "Starting Open WebUI container..."
  local started=false
  for attempt in $(seq 1 10); do
    local cid
    cid=$($D run -d \
      --name open-webui \
      --restart unless-stopped \
      -p "${host_port}:8080" \
      --add-host host.docker.internal:host-gateway \
      -v open-webui-data:/app/backend/data \
      -e OPENAI_API_BASE_URL="$openwebui_url" \
      -e OPENAI_API_KEY="$api_key" \
      -e BYPASS_MODEL_ACCESS_CONTROL=true \
      -e AIOHTTP_CLIENT_TIMEOUT=120 \
      "$OPENWEBUI_IMAGE" 2>&1) || {
      warn "Docker bind failed (attempt $attempt/10): $(echo "$cid" | tail -1)"
      $D rm -f open-webui >/dev/null 2>&1 || true
      sleep 10
      continue
    }
    if $D inspect --format='{{.State.Status}}' open-webui 2>/dev/null | grep -q running; then
      started=true
      break
    fi
    warn "Container exited (attempt $attempt/10):"
    $D logs open-webui 2>&1 | while IFS= read -r line; do warn "  $line"; done
    $D rm -f open-webui >/dev/null 2>&1 || true
    sleep 10
  done
  if [[ "$started" != "true" ]]; then
    error "Could not start Open WebUI container after 10 attempts"
    error "  Check logs above or try: sudo service docker restart"
    exit 125
  fi
  info "Open WebUI container started"
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
  [[ -f "$STATE_FILE" ]] || return 0
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
