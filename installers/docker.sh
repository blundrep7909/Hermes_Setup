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

header "Hermes Setup – Docker Mode (All Containerized)"
echo ""

validate_home

# ─── Prerequisites ─────────────────────────────────────────────────────
rollback_init
rollback_step "detection"

OS="$(detect_os)"
WSL="$(detect_wsl)"
info "OS: $OS | Platform: $WSL"

if [[ "$WSL" == "wsl2" ]]; then
  warn "WSL2 detected. AionUi GUI won't work in Docker mode (no display)."
  warn "  This is expected — AionUi runs headless in Docker."
fi

check_docker

rollback_step "port_check"
port_check 8642 "Hermes API" || exit 1
port_check 3000 "Open WebUI" || exit 1
port_check 3001 "AionUi" || exit 1

# ─── Generate Credentials ─────────────────────────────────────────────
rollback_step "keygen"
generate_key

# ─── Write Configs ────────────────────────────────────────────────────
rollback_step "config_written"
ensure_hermes_config
ensure_hermes_env

# ─── Persist Mode ─────────────────────────────────────────────────────
store_mode "docker"

# ─── Deploy Containers ────────────────────────────────────────────────
rollback_step "compose_build"
info "Building AionUi Docker image (custom, with hermes-agent[acp])..."
$DC -f "$COMPOSE_DIR/docker-compose.yml" build aionui

rollback_step "compose_up"
info "Starting all containers (Hermes + Open WebUI + AionUi)..."
export API_SERVER_KEY
$DC -f "$COMPOSE_DIR/docker-compose.yml" up -d

# ─── Verification ─────────────────────────────────────────────────────
rollback_step "verify"
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
echo "  Mode:         Docker (all 3 in containers)"
echo "  Hermes API:   http://localhost:8642/v1"
echo "  Open WebUI:   http://localhost:3000"
echo "  AionUi:       http://localhost:3001"
echo ""
echo "  To configure providers:"
echo "    docker exec -it hermes /opt/hermes/.venv/bin/hermes setup"
echo ""
echo "  To view logs: docker compose -f $COMPOSE_DIR/docker-compose.yml logs -f"
  echo "  To recheck:   bash $DOCTOR_SCRIPT"
echo ""
