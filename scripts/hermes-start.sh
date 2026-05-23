#!/usr/bin/env bash
# Start Hermes Gateway (API Server + ACP)
# Usage: bash ~/.hermes-setup/hermes-start.sh
source ~/.hermes/.env
exec ~/.hermes-venv/bin/hermes gateway run --replace
