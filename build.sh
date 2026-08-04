#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

cd "$(dirname "$0")"
exec docker compose build "$@" --build-arg NGINX_IMAGE="${NGINX_IMAGE:-nginx:stable-bookworm}"
