#!/usr/bin/env bash
# Start AionUi WebUI (Headless mode)
# Usage: bash ~/.hermes-setup/aionui-start.sh
BUN_BIN=""
for b in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun"; do
  [[ -x "$b" ]] && { BUN_BIN="$b"; break; }
done
[[ -z "$BUN_BIN" ]] && BUN_BIN="$HOME/.bun/bin/bun"
cd "$HOME/hermes-aionui" && exec "$BUN_BIN" run start --webui --port 3001
