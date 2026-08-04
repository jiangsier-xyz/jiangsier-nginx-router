#!/usr/bin/env bash
set -euo pipefail

echo "== nginx -t =="
docker compose exec nginx-router nginx -t

echo "== live certs =="
docker compose exec nginx-router sh -c 'ls -1 /etc/letsencrypt/live/*/ 2>/dev/null || echo "(none yet)"'

echo "== renewal configs =="
docker compose exec nginx-router sh -c 'ls -1 /etc/letsencrypt/renewal/ 2>/dev/null || echo "(none yet)"'
