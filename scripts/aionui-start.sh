#!/usr/bin/env bash
# Start AionUi Server (WebUI production mode)
# Usage: bash ~/.hermes-setup/aionui-start.sh
export PATH="$HOME/.bun/bin:$PATH"
BUN_BIN=""
for b in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun"; do
  [[ -x "$b" ]] && { BUN_BIN="$b"; break; }
done
[[ -z "$BUN_BIN" ]] && BUN_BIN="$HOME/.bun/bin/bun"
cd "$HOME/hermes-aionui" && exec "$BUN_BIN" run webui:prod
