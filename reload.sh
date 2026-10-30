#!/usr/bin/env bash
# reload.sh — Hot-reload the nginx configuration without restarting the container.
#
# It does three things:
#   1. Re-sync the sites-available -> sites-enabled symlinks (same logic as
#      enable_sites in entrypoint.sh: only stale symlinks are removed, regular
#      files are left alone), so newly added confs take effect;
#   2. Validate the configuration with nginx -t; on failure it aborts and the
#      old configuration keeps serving;
#   3. Hot-reload with nginx -s reload.
#
# Note: this script only reloads the configuration; it does not trigger certbot
# issuance or renewal. Adding a conf for a NEW domain still requires the
# container startup flow for certificates; adding paths under an existing
# domain, or editing existing configuration, is fully covered by this script.
#
# Usage: ./reload.sh [container-name]   # defaults to nginx-router

set -euo pipefail
cd "$(dirname "$0")"

CONTAINER="${1:-nginx-router}"

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" != "true" ]]; then
  echo "[reload] container $CONTAINER is not running; start it with ./run.sh first" >&2
  exit 1
fi

docker exec "$CONTAINER" sh -c '
  mkdir -p /etc/nginx/sites-enabled
  find /etc/nginx/sites-enabled -maxdepth 1 -type l -delete
  for f in /etc/nginx/sites-available/*; do
    [ -f "$f" ] || continue
    ln -sfn "$f" "/etc/nginx/sites-enabled/$(basename "$f")"
  done
'

docker exec "$CONTAINER" nginx -t
docker exec "$CONTAINER" nginx -s reload
echo "[reload] nginx configuration reloaded"
