# nginx-router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Docker container (image `nginx-router`) running nginx as PID 1 with certbot, where externally-edited site configs in a mounted volume are auto-enabled and have their Let's Encrypt certificates issued/renewed automatically.

**Architecture:** Single container from `nginx:1.27-bookworm`. `entrypoint.sh` symlinks `/etc/nginx/sites-available/*` → `/etc/nginx/sites-enabled/`, writes self-signed bootstrap placeholders for domains lacking a real cert, starts nginx in the foreground, runs `certbot certonly --webroot` per domain, reloads, and starts a 12h renewal loop. Pure parsing logic is factored into `lib/parse.sh` (unit-tested in plain bash) and sourced by the entrypoint.

**Tech Stack:** Bash, nginx 1.27 (bookworm), certbot (apt), Docker, Docker Compose.

## Global Constraints

- Base image pinned to `nginx:1.27-bookworm`.
- certbot installed via `apt-get install -y --no-install-recommends certbot`.
- Entrypoint runs under `set -euo pipefail` and must exit (container stops) on any unhandled error — per spec "exit if any exception was raised."
- `CERTBOT_EMAIL` is required; exit if unset.
- `USE_STAGING=1` switches certbot to `--staging`.
- Persist the **whole** `/etc/letsencrypt` (named volume), not just `/live`.
- `compose.yml` must NOT set `restart:` (failures stay visible).
- Docker is required to run the build/nginx -t verification steps; the plain-bash parsing test runs without Docker.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/parse.sh` | Pure function `extract_domains_from_dir <dir>` — prints domains referenced by `/etc/letsencrypt/live/<DOMAIN>/` paths. Sourced by entrypoint and tests. |
| `tests/test_parse.sh` | Plain-bash unit test for `extract_domains_from_dir`. No external deps. |
| `entrypoint.sh` | Container PID 1. Sources `lib/parse.sh`. Enables sites, bootstraps placeholders, starts nginx, issues/renews certs, reloads, starts renewal loop, traps signals, blocks. |
| `nginx/nginx.conf` | Base nginx config; `include /etc/nginx/sites-enabled/*`. |
| `nginx/includes/acme.conf` | Reusable `/.well-known/acme-challenge/` webroot location. |
| `Dockerfile` | Builds the image; installs certbot; copies config + entrypoint; sets `ENTRYPOINT`. |
| `compose.yml` | Service definition, ports, volumes, env. |
| `build.sh` | `docker compose build`. |
| `run.sh` | Loads `.env`, requires `CERTBOT_EMAIL`, `docker compose up -d`. |
| `examples/example.conf` | Reference site config (NOT mounted — prevents accidental issuance for `example.com`). |
| `sites-available/.gitkeep` | Keeps the mounted bind dir present in the repo; empty by default. |
| `README.md` | Usage + the site-config contract. |
| `scripts/verify.sh` | Optional smoke checks (`nginx -t`, list live certs). |

---

### Task 1: Parsing library + test (TDD)

**Files:**
- Create: `lib/parse.sh`
- Create: `tests/test_parse.sh`

**Interfaces:**
- Produces: `extract_domains_from_dir <dir>` (bash function, prints unique domains to stdout, one per line). Consumed by `entrypoint.sh` (Task 3).

- [ ] **Step 1: Write the failing test**

Create `tests/test_parse.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/parse.sh"

fail=0
TMP="$(mktemp -d)"

# Fixture: two servers referencing two distinct domains.
mkdir -p "$TMP/sites-enabled"
cat > "$TMP/sites-enabled/site.conf" <<'EOF'
server {
    listen 443 ssl;
    server_name mini-2.tongyi.cn;
    ssl_certificate     /etc/letsencrypt/live/mini-2.tongyi.cn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mini-2.tongyi.cn/privkey.pem;
}
server {
    listen 443 ssl;
    server_name a.example.com b.example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
}
EOF

got="$(extract_domains_from_dir "$TMP/sites-enabled" | sort)"
want="$(printf 'example.com\nmini-2.tongyi.cn')"
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_parse.sh`
Expected: FAIL (or "source: No such file" — `lib/parse.sh` does not exist yet).

- [ ] **Step 3: Write the minimal implementation**

Create `lib/parse.sh`:

```bash
#!/usr/bin/env bash
# Pure parsing helpers. Sourced by entrypoint.sh and tests/test_parse.sh.
# Do not put top-level side effects here; this file is sourced, not executed.

# extract_domains_from_dir <dir>
# Print unique domains referenced by /etc/letsencrypt/live/<DOMAIN>/ paths
# across all *.conf files in <dir>. One domain per line.
extract_domains_from_dir() {
  local dir="$1"
  local f
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    grep -hoE '/etc/letsencrypt/live/[^/]+/' "$f" 2>/dev/null || true
  done | sed -E 's#.*/live/([^/]+)/.*#\1#' | sort -u
  shopt -u nullglob
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_parse.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add lib/parse.sh tests/test_parse.sh
git commit -m "feat: add domain-extraction parsing library with tests"
```

---

### Task 2: nginx base config + ACME include

**Files:**
- Create: `nginx/nginx.conf`
- Create: `nginx/includes/acme.conf`

**Interfaces:**
- Produces: `/etc/nginx/nginx.conf` (image path) with `include /etc/nginx/sites-enabled/*;` and `/etc/nginx/conf.d/*.conf;`. Produces `/etc/nginx/includes/acme.conf` referenced by user site configs via `include /etc/nginx/includes/acme.conf;`.

- [ ] **Step 1: Write the base nginx config**

Create `nginx/nginx.conf`:

```nginx
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" "$http_user_agent"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;
    keepalive_timeout  65;
    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
```

- [ ] **Step 2: Write the ACME webroot include**

Create `nginx/includes/acme.conf`:

```nginx
# Reusable Let's Encrypt HTTP-01 challenge location.
# Include in any server block that listens on :80 for the domain.
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
    default_type "text/plain";
}
```

- [ ] **Step 3: Verify the nginx config is syntactically plausible**

If Docker is available:
Run: `docker run --rm -v "$(pwd)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$(pwd)/nginx/includes:/etc/nginx/includes:ro" nginx:1.27-bookworm nginx -t`
Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful` (sites-enabled/* is empty in this ad-hoc run, which is fine).

If Docker is NOT available: skip; visual review only. Note this in the commit message.

- [ ] **Step 4: Commit**

```bash
git add nginx/nginx.conf nginx/includes/acme.conf
git commit -m "feat: add nginx base config and ACME webroot include"
```

---

### Task 3: entrypoint.sh

**Files:**
- Create: `entrypoint.sh`

**Interfaces:**
- Consumes: `extract_domains_from_dir <dir>` from `lib/parse.sh` (Task 1).
- Produces: an executable `/entrypoint.sh` (image path) that is the container `ENTRYPOINT`. Uses env: `CERTBOT_EMAIL` (required), `USE_STAGING` (optional, `1` enables staging). Uses fixed paths: `/etc/nginx/sites-available`, `/etc/nginx/sites-enabled`, `/var/www/certbot`, `/etc/letsencrypt`.

- [ ] **Step 1: Write the entrypoint**

Create `entrypoint.sh`:

```bash
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
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL environment variable is required}"
STAGING_FLAG=""
if [[ "${USE_STAGING:-0}" == "1" ]]; then
  STAGING_FLAG="--staging"
  log "Using Let's Encrypt STAGING environment"
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
  local domain="$1"
  [[ -f "$LE_ROOT/live/$domain/fullchain.pem" \
     && -f "$LE_ROOT/live/$domain/privkey.pem" \
     && -f "$LE_ROOT/renewal/$domain.conf" ]]
}

make_placeholder() {
  local domain="$1"
  local dir="$LE_ROOT/live/$domain"
  mkdir -p "$dir"
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
  if has_real_cert "$domain"; then
    log "renew (if due): $domain"
    certbot renew --cert-name "$domain" --non-interactive
  else
    log "issue: $domain"
    # nginx already loaded the placeholder into memory; removing the on-disk
    # files lets certbot create a clean lineage. Safe until we reload.
    rm -f "$LE_ROOT/live/$domain/fullchain.pem" "$LE_ROOT/live/$domain/privkey.pem"
    certbot certonly --webroot -w "$WEBROOT" -d "$domain" \
      --email "$CERTBOT_EMAIL" --agree-tos --non-interactive $STAGING_FLAG
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

# bootstrap placeholders for any domain lacking a real cert
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  has_real_cert "$d" || make_placeholder "$d"
done <<< "$DOMAINS"

start_nginx_bg

# issue/renew each domain
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  issue_or_renew "$d"
done <<< "$DOMAINS"

nginx -s reload
log "nginx reloaded with real certs"

start_renewal_loop

trap 'nginx -s stop; wait "$NGINX_PID" 2>/dev/null || true' TERM INT

log "ready"
wait "$NGINX_PID"
```

- [ ] **Step 2: Lint with shellcheck if available; otherwise syntax-check**

Run: `command -v shellcheck >/dev/null && shellcheck entrypoint.sh || bash -n entrypoint.sh`
Expected: no output (syntax OK). If shellcheck is present, fix any reported issues.

- [ ] **Step 3: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: add entrypoint that enables sites and manages certs"
```

---

### Task 4: Dockerfile

**Files:**
- Create: `Dockerfile`

**Interfaces:**
- Consumes: `nginx/nginx.conf`, `nginx/includes/acme.conf`, `entrypoint.sh`, `lib/parse.sh`.
- Produces: image `nginx-router` with files at `/etc/nginx/nginx.conf`, `/etc/nginx/includes/acme.conf`, `/entrypoint.sh` (executable), `/lib/parse.sh`, and `ENTRYPOINT ["/entrypoint.sh"]`.

- [ ] **Step 1: Write the Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM nginx:1.27-bookworm

# Install certbot
RUN apt-get update \
 && apt-get install -y --no-install-recommends certbot \
 && rm -rf /var/lib/apt/lists/*

# nginx configuration
COPY nginx/nginx.conf        /etc/nginx/nginx.conf
COPY nginx/includes/acme.conf /etc/nginx/includes/acme.conf

# Entrypoint + parsing library
COPY entrypoint.sh  /entrypoint.sh
COPY lib/parse.sh   /lib/parse.sh
RUN chmod +x /entrypoint.sh

# Runtime directories
RUN mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/certbot

ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: Build the image (requires Docker)**

Run: `docker build -t nginx-router:local .`
Expected: image builds successfully.

If Docker is NOT available: skip the build; note it. Visual review of the Dockerfile against the `nginx:1.27-bookworm` layout.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile building nginx + certbot image"
```

---

### Task 5: compose.yml

**Files:**
- Create: `compose.yml`

**Interfaces:**
- Consumes: image built from `Dockerfile` (Task 4). Uses env `CERTBOT_EMAIL` (required), `USE_STAGING` (optional).
- Produces: a `nginx-router` service exposing ports 80/443, bind `./sites-available:/etc/nginx/sites-available:ro`, named volume `nginx-router-le:/etc/letsencrypt`, bind `./logs:/var/log/nginx`.

- [ ] **Step 1: Write compose.yml**

Create `compose.yml`:

```yaml
services:
  nginx-router:
    build: .
    image: nginx-router:latest
    container_name: nginx-router
    ports:
      - "80:80"
      - "443:443"
    environment:
      CERTBOT_EMAIL: ${CERTBOT_EMAIL:?CERTBOT_EMAIL must be set}
      USE_STAGING: ${USE_STAGING:-0}
    volumes:
      - ./sites-available:/etc/nginx/sites-available:ro
      - nginx-router-le:/etc/letsencrypt
      - ./logs:/var/log/nginx

volumes:
  nginx-router-le:
```

- [ ] **Step 2: Validate the compose file (requires Docker)**

Run: `docker compose config >/dev/null`
Expected: exits 0. Then test the failure path: `docker compose config` with `CERTBOT_EMAIL` unset should error.

If Docker is NOT available: skip; visual review only.

- [ ] **Step 3: Commit**

```bash
git add compose.yml
git commit -m "feat: add compose service with volumes and env"
```

---

### Task 6: build.sh + run.sh

**Files:**
- Create: `build.sh`
- Create: `run.sh`

**Interfaces:**
- Consumes: `compose.yml` (Tasks 4–5).
- Produces: `build.sh` (builds image via `docker compose build`), `run.sh` (loads `.env`, requires `CERTBOT_EMAIL`, runs `docker compose up -d`). Both `chmod +x`ed.

- [ ] **Step 1: Write build.sh**

Create `build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec docker compose build "$@"
```

- [ ] **Step 2: Write run.sh**

Create `run.sh`:

```bash
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
```

- [ ] **Step 3: Make both executable and syntax-check**

Run: `chmod +x build.sh run.sh && bash -n build.sh && bash -n run.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add build.sh run.sh
git commit -m "feat: add build.sh and run.sh wrappers"
```

---

### Task 7: example config, .gitkeep, README, .gitignore

**Files:**
- Create: `examples/example.conf`
- Create: `sites-available/.gitkeep`
- Create: `README.md`
- Create: `.gitignore`

**Interfaces:**
- Produces: documentation of the site-config contract; a reference config (deliberately NOT mounted, to avoid issuing for `example.com`); an empty `sites-available/` for the bind mount.

- [ ] **Step 1: Write the example site config**

Create `examples/example.conf`:

```nginx
# Reference site config — copy into sites-available/ and edit server_name + backend.
# Do NOT enable this file as-is: it references example.com, which you do not own,
# and certbot issuance would fail.

server {
    listen 80;
    server_name example.com;
    include /etc/nginx/includes/acme.conf;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        # Replace with your backend, e.g.:
        # proxy_pass http://127.0.0.1:8080;
        return 200 "hello from example.com\n";
    }
}
```

- [ ] **Step 2: Keep the bind-mount dir present in the repo**

Create `sites-available/.gitkeep` (empty file). This ensures `./sites-available` exists so the compose bind mount resolves.

- [ ] **Step 3: Write .gitignore**

Create `.gitignore`:

```
.env
logs/
```

- [ ] **Step 4: Write the README**

Create `README.md`:

````markdown
# nginx-router

nginx + certbot in one container, with externally-editable routing configs and
automatic Let's Encrypt certificate issuance/renewal.

## Quick start

1. Put your site configs (regular `.conf` files) in `sites-available/`.
   See `examples/example.conf` for the contract.
2. Create a `.env` file (or export the var):

   ```
   CERTBOT_EMAIL=you@example.com
   # USE_STAGING=1   # uncomment while testing to avoid LE rate limits
   ```

3. Build and run:

   ```bash
   ./build.sh
   ./run.sh
   ```

The container listens on host ports 80 and 443.

## Site-config contract

Each file in `sites-available/` is enabled automatically (symlinked into
`sites-enabled` on container start). To have its certificate managed, the file
must reference the cert path:

```nginx
ssl_certificate     /etc/letsencrypt/live/<DOMAIN>/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/<DOMAIN>/privkey.pem;
```

and must include the ACME challenge location on a port-80 server so HTTP-01
verification succeeds:

```nginx
server {
    listen 80;
    server_name <DOMAIN>;
    include /etc/nginx/includes/acme.conf;
    return 301 https://$host$request_uri;
}
```

The entrypoint derives `<DOMAIN>` from the `ssl_certificate` path — no separate
domain list is needed.

## Volumes

| Host path / volume | Container path | Purpose |
|---|---|---|
| `./sites-available` | `/etc/nginx/sites-available` | Edit your configs here (read-only in container) |
| named `nginx-router-le` | `/etc/letsencrypt` | Persistent cert state (live + archive + renewal + accounts) |
| `./logs` | `/var/log/nginx` | Access/error logs |

## Environment

| Var | Required | Purpose |
|---|---|---|
| `CERTBOT_EMAIL` | yes | Let's Encrypt account email |
| `USE_STAGING` | no | `1` uses the LE staging endpoint (untrusted certs, no rate limits) |

## How it works

On start the entrypoint:

1. Symlinks every file in `sites-available/*` into `sites-enabled/`.
2. For each domain referenced by an `ssl_certificate` path with no real cert,
   writes a 1-day self-signed placeholder so nginx can boot.
3. Runs `nginx -t`, then starts nginx in the foreground (PID 1).
4. For each domain, runs `certbot certonly --webroot` (issues if absent) or
   `certbot renew --cert-name <DOMAIN>` (renews if due).
5. Reloads nginx to pick up real certs.
6. Starts a background loop running `certbot renew` every 12h, reloading nginx
   on each successful renewal.

Any error exits the container (it does not auto-restart), so failures are
visible.
````

- [ ] **Step 5: Commit**

```bash
git add examples/example.conf sites-available/.gitkeep README.md .gitignore
git commit -m "docs: add example config, README, and gitignore"
```

---

### Task 8: Verification smoke script

**Files:**
- Create: `scripts/verify.sh`

**Interfaces:**
- Produces: `scripts/verify.sh` — runs `nginx -t` inside the running container and lists `/etc/letsencrypt/live/*`. Requires Docker + a running container.

- [ ] **Step 1: Write the verify script**

Create `scripts/verify.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "== nginx -t =="
docker compose exec nginx-router nginx -t

echo "== live certs =="
docker compose exec nginx-router sh -c 'ls -1 /etc/letsencrypt/live/*/ 2>/dev/null || echo "(none yet)"'

echo "== renewal configs =="
docker compose exec nginx-router sh -c 'ls -1 /etc/letsencrypt/renewal/ 2>/dev/null || echo "(none yet)"'
```

- [ ] **Step 2: Make executable and syntax-check**

Run: `chmod +x scripts/verify.sh && bash -n scripts/verify.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/verify.sh
git commit -m "chore: add verification smoke script"
```

---

### Task 9: End-to-end build + start verification (requires Docker)

**Files:**
- None (verification only).

**Interfaces:**
- Consumes: everything from Tasks 1–8.

- [ ] **Step 1: Build the image**

Run: `./build.sh`
Expected: image builds; `docker images nginx-router` lists it.

- [ ] **Step 2: Start with no site configs**

Run: `CERTBOT_EMAIL=test@example.com ./run.sh`
Expected: container starts; `docker compose logs nginx-router` shows `[entrypoint] domains:` empty, `nginx started`, `ready`. `curl -s http://localhost/` connects (nginx responds, likely 404/default).

- [ ] **Step 3: Validate config inside the running container**

Run: `./scripts/verify.sh`
Expected: `nginx -t` succeeds; live certs `(none yet)`.

- [ ] **Step 4: Stop**

Run: `docker compose down`
Expected: container removed cleanly.

- [ ] **Step 5: Commit (if any tweaks were made)**

If Tasks 1–8 needed no changes, this task is verification-only — no commit. If fixes were applied, commit them with a descriptive message.

---

## Self-Review (run after writing — done)

**Spec coverage:**
- nginx + certbot image, base image choice → Task 4. ✓
- `/etc/nginx/sites-available` volume (was sites-enabled; settled to sites-available during brainstorming) → Task 5; entrypoint linking → Task 3. ✓
- `/etc/letsencrypt` volume (whole dir) → Task 5. ✓
- Entrypoint scans + creates links, auto-enables → Task 3 (`enable_sites`). ✓
- Entrypoint handles certs: renew if exists+due, issue if missing → Task 3 (`issue_or_renew`). ✓
- Interact / exit on exception → `set -euo pipefail` + `die`, no `restart:` → Tasks 3, 5. ✓
- Dockerfile, compose.yml, build.sh, run.sh → Tasks 4, 5, 6. ✓

**Placeholder scan:** No TBD/TODO/"add error handling". All code blocks are complete. ✓

**Type/name consistency:** `extract_domains_from_dir` defined in Task 1 and used in Task 3. `has_real_cert`, `make_placeholder`, `issue_or_renew`, `start_nginx_bg`, `start_renewal_loop`, `enable_sites` defined and called consistently in Task 3. `NGINX_PID` set in `start_nginx_bg` and referenced in the trap + `wait`. ✓

One subtlety confirmed: `nginx -t` loads SSL cert files, so placeholders must exist before `start_nginx_bg` runs — the entrypoint makes placeholders first, then calls `start_nginx_bg`. Order is correct. ✓
