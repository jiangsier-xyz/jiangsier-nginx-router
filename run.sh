#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Load .env if present so CERTBOT_EMAIL can live there.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required. Export it or put it in .env}"
export CERTBOT_EMAIL
export USE_STAGING="${USE_STAGING:-0}"

exec docker compose up -d "$@"
