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

: "${USE_CERTBOT:=1}"
export USE_CERTBOT
export USE_STAGING="${USE_STAGING:-0}"

if [[ "$USE_CERTBOT" == "1" ]]; then
  : "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required when USE_CERTBOT=1. Export it or put it in .env}"
fi
export CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

exec docker compose up -d "$@"
