#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/parse.sh"

fail=0
TMP="$(mktemp -d)"

# The primary domain under test is read from an env var (defaulting to a
# non-real .test domain) so no real domain is committed to the repo.
DOMAIN="${TEST_DOMAIN:-app.example.test}"

# Fixture: two servers referencing two distinct domains.
mkdir -p "$TMP/sites-enabled"
cat > "$TMP/sites-enabled/site.conf" <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
}
server {
    listen 443 ssl;
    server_name a.example.com b.example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
}
EOF

got="$(extract_domains_from_dir "$TMP/sites-enabled" | sort)"
want="$(printf '%s\nexample.com' "$DOMAIN" | sort)"
if [[ "$got" != "$want" ]]; then
  echo "FAIL: expected [$want], got [$got]"; fail=1
fi

# Fixture: a config with no LE paths yields no domains.
mkdir -p "$TMP/empty"
cat > "$TMP/empty/none.conf" <<'EOF'
server { listen 80; server_name x.test; return 200; }
EOF
got="$(extract_domains_from_dir "$TMP/empty")"
if [[ -n "$got" ]]; then
  echo "FAIL: expected empty, got [$got]"; fail=1
fi

# Fixture: a missing dir yields nothing (does not error).
got="$(extract_domains_from_dir "$TMP/does-not-exist")"
if [[ -n "$got" ]]; then
  echo "FAIL: expected empty for missing dir, got [$got]"; fail=1
fi

rm -rf "$TMP"

if [[ $fail -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
