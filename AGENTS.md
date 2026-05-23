# AGENTS.md – Hermes Setup Context

## Architecture SSOT
Hermes Agent is the single source of truth. Both UIs (Open WebUI, AionUi) consume
Hermes' OpenAI-compatible API. Never replicate provider/model config in UI configs.

## Critical URL Rule
Always append `/v1` to `OPENAI_API_BASE_URL`. Without it, Open WebUI silently
returns zero models. Strip trailing slashes before appending.

## Healthcheck Safety
Open WebUI `/health` is a trivial `return {"status": true}` — no model enumeration,
no DB queries. Safe to use as Docker healthcheck. Hermes healthcheck MUST include
Bearer auth header.

## Applied Bug Fixes (from real-world issues)
- `auxiliary.compression.timeout: 300` — prevents 8x retry rate (hermes-agent#22986)
- `BYPASS_MODEL_ACCESS_CONTROL=true` — models not private by default (open-webui#7931)
- `AIOHTTP_CLIENT_TIMEOUT=120` — default None = infinite hang (open-webui env.py)
- AionUi runs headless `--webui` always (host mode); WSL detection uses multi-iface IP (eth0→eth1→bond0) for Open WebUI docker host access (aionui#2748)

## Avoid These Mistakes
- Do NOT use `OPENAI_BASE_URL` (wrong name; must be `OPENAI_API_BASE_URL`)
- Do NOT set `OPENAI_API_KEY=***` literal string
- Do NOT `chmod 666 /var/run/docker.sock`
- Do NOT source-patch Hermes at runtime
- Do NOT use SQL injection in password scripts
- Do NOT use named volumes for Hermes config (use bind mount)

## Verification
Always run `~/Hermes_Setup/scripts/doctor.sh` after install to validate all endpoints.
