#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# nginx-router entrypoint (PID 1)
# 1. enable sites: symlink /etc/nginx/sites-available/* -> /etc/nginx/sites-enabled/
# 2. for each domain referenced via ssl_certificate /etc/letsencrypt/live/<DOMAIN>/,
#    write a self-signed placeholder if no real cert exists (so nginx can boot)
# 3. nginx -t && start nginx (foreground, backgrounded from the shell)
# 4. certbot certonly --webroot per domain (issue if absent, renew handled too)
# 5. nginx -s reload
# 6. background 12h renewal loop
# 7. trap TERM/INT -> nginx -s stop; wait on nginx
# Exit on any error.
# ---------------------------------------------------------------------------

source /lib/parse.sh

SITES_AVAILABLE="${SITES_AVAILABLE:-/etc/nginx/sites-available}"
SITES_ENABLED="${SITES_ENABLED:-/etc/nginx/sites-enabled}"
WEBROOT="${WEBROOT:-/var/www/certbot}"
LE_ROOT="${LE_ROOT:-/etc/letsencrypt}"
NGINX_PID=""

log() { echo "[entrypoint] $*" >&2; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# 1. validate env
USE_CERTBOT="${USE_CERTBOT:-1}"
STAGING_FLAG=""
if [[ "$USE_CERTBOT" == "1" ]]; then
  : "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required when USE_CERTBOT=1}"
  if [[ "${USE_STAGING:-0}" == "1" ]]; then
    STAGING_FLAG="--staging"
    log "Using Let's Encrypt STAGING environment"
  fi
else
  log "certbot disabled (USE_CERTBOT=0); provide certs manually under $LE_ROOT/live/<DOMAIN>/"
fi

# --- helpers ----------------------------------------------------------------

enable_sites() {
  mkdir -p "$SITES_ENABLED"
  # remove stale symlinks only (leave regular files alone)
  find "$SITES_ENABLED" -maxdepth 1 -type l -delete
  local f base
  shopt -s nullglob
  for f in "$SITES_AVAILABLE"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    ln -sfn "$f" "$SITES_ENABLED/$base"
    log "enabled: $base"
  done
  shopt -u nullglob
}

has_real_cert() {
  # certbot-managed cert: real files + a renewal config
  local domain="$1"
  [[ -f "$LE_ROOT/live/$domain/fullchain.pem" \
     && -f "$LE_ROOT/live/$domain/privkey.pem" \
     && -f "$LE_ROOT/renewal/$domain.conf" ]]
}

has_cert_files() {
  # any cert files on disk (managed OR manually placed)
  local domain="$1"
  [[ -f "$LE_ROOT/live/$domain/fullchain.pem" \
     && -f "$LE_ROOT/live/$domain/privkey.pem" ]]
}

make_placeholder() {
  local domain="$1"
  local dir="$LE_ROOT/live/$domain"
  mkdir -p "$dir"
  umask 077
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
    -subj "/CN=$domain" -days 1 >/dev/null 2>&1
  log "placeholder cert for $domain"
}

start_nginx_bg() {
  nginx -t
  nginx -g 'daemon off;' &
  NGINX_PID=$!
  sleep 1
  if ! kill -0 "$NGINX_PID" 2>/dev/null; then
    die "nginx failed to start"
  fi
  log "nginx started (pid $NGINX_PID)"
}

issue_or_renew() {
  local domain="$1"
  if ! has_cert_files "$domain"; then
    log "issue: $domain"
    # nginx already loaded the placeholder into memory; removing the on-disk
    # files lets certbot create a clean lineage. Safe until we reload.
    rm -f "$LE_ROOT/live/$domain/fullchain.pem" "$LE_ROOT/live/$domain/privkey.pem"
    certbot certonly --webroot -w "$WEBROOT" -d "$domain" \
      --email "$CERTBOT_EMAIL" --agree-tos --non-interactive $STAGING_FLAG
  elif has_real_cert "$domain"; then
    log "renew (if due): $domain"
    certbot renew --cert-name "$domain" --non-interactive
  else
    log "manual cert present for $domain — skipping certbot"
  fi
}

start_renewal_loop() {
  (
    while true; do
      sleep 12h
      certbot renew --non-interactive --deploy-hook "nginx -s reload" \
        || log "renewal run reported failures"
    done
  ) &
  log "renewal loop started (pid $!)"
}

# --- main -------------------------------------------------------------------

mkdir -p "$WEBROOT"
enable_sites

DOMAINS="$(extract_domains_from_dir "$SITES_ENABLED")"
log "domains: ${DOMAINS//$'\n'/, }"

# bootstrap placeholders for any domain lacking cert files on disk
# (manually-placed certs are left untouched). Skipped when certbot is disabled,
# since placeholders only exist to bootstrap certbot issuance.
if [[ "$USE_CERTBOT" == "1" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    has_cert_files "$d" || make_placeholder "$d"
  done <<< "$DOMAINS"
fi

start_nginx_bg

trap 'nginx -s stop 2>/dev/null || true; wait "$NGINX_PID" 2>/dev/null || true' TERM INT

# issue/renew each domain, then reload and start the renewal loop.
# All skipped when certbot is disabled (manual mode).
if [[ "$USE_CERTBOT" == "1" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    issue_or_renew "$d"
  done <<< "$DOMAINS"

  nginx -s reload
  log "nginx reloaded with real certs"

  start_renewal_loop
fi

log "ready"
wait "$NGINX_PID"
