# nginx-router design

A single Docker container running **nginx in the foreground** (PID 1), with `certbot`
managing Let's Encrypt certificates. Routing configurations are edited externally via a
mounted volume; the entrypoint auto-enables them and ensures certificates exist or are
renewed before nginx serves traffic.

## Goals

- nginx + certbot in one image.
- Externally editable routing configs (drop a file in the volume → enabled on next start).
- Automatic issuance and renewal of Let's Encrypt certs for every domain referenced in the
  configs.
- Exit on any error so failures are visible.

## Non-goals

- No load balancing, no Lua, no stream modules beyond stock nginx.
- No web UI for config editing.
- No automatic DNS-01 support (HTTP-01 only).

## Decisions (settled in brainstorming)

| Decision | Choice |
|---|---|
| Cert method | Webroot (`--webroot -w /var/www/certbot`) + self-signed bootstrap placeholder |
| LE environment | Production by default; staging via `USE_STAGING=1` |
| Registration | `CERTBOT_EMAIL` required via env; `--email` + `--agree-tos`; exit if unset |
| Volume layout | `/etc/nginx/sites-available` is the externally-edited volume; entrypoint symlinks all of it into `sites-enabled` |
| LE persistence | Whole `/etc/letsencrypt` persisted (live/, archive/, renewal/, accounts/) |
| Renewal timing | One-shot at start + background `sleep 12h` loop |

## Architecture

Single container, image `nginx-router`, base `nginx:1.27-bookworm` (Debian so `certbot`
installs cleanly via `apt`). nginx runs in the foreground as PID 1; the entrypoint runs
certbot before nginx stays up and runs a background renewal loop.

### Inside-image paths

| Path | Role |
|---|---|
| `/etc/nginx/nginx.conf` | Custom base config; `include /etc/nginx/sites-enabled/*` |
| `/etc/nginx/sites-available/` | **Volume** — user edits these externally |
| `/etc/nginx/sites-enabled/` | Ephemeral — entrypoint repopulates from symlinks on each start |
| `/etc/nginx/includes/acme.conf` | Reusable ACME webroot location snippet |
| `/var/www/certbot/` | ACME webroot (created by entrypoint) |
| `/etc/letsencrypt/` | **Volume** — durable cert state |

### Volumes

- `./sites-available` → `/etc/nginx/sites-available` (bind mount, the "edit externally" surface)
- `nginx-router-le` → `/etc/letsencrypt` (named volume, durable)
- `./logs` → `/var/log/nginx` (optional, bind)

## Entrypoint algorithm (`entrypoint.sh`)

`set -euo pipefail`; a trap exits the container on any unhandled error.

1. **Validate env** — exit if `CERTBOT_EMAIL` is unset.
2. **Enable sites** — remove stale symlinks in `sites-enabled`, then symlink every file in
   `sites-available/*` into `sites-enabled/` (the "create links for them" step).
3. **Parse configs** — for each enabled site, extract `server_name` domains and the domains
   referenced by `ssl_certificate /etc/letsencrypt/live/<DOMAIN>/fullchain.pem`.
4. **Bootstrap placeholders** — for each domain whose real cert is missing, write a 1-day
   self-signed cert to `/etc/letsencrypt/live/<DOMAIN>/{fullchain,privkey}.pem` so nginx can
   start (chicken-and-egg solved).
5. **`nginx -t`** — validate; exit on syntax error.
6. **Start nginx** — `nginx -g 'daemon off;' &`; capture `$NGINX_PID`; sleep / poll the
   listener.
7. **Issue/renew** — for each domain:
   - If it has only a placeholder (no real cert), remove the placeholder files (nginx already
     loaded them into memory, so deletion is safe until reload) and run
     `certbot certonly --webroot -w /var/www/certbot -d <DOMAIN> --email "$CERTBOT_EMAIL"
     --agree-tos $STAGING_FLAG`.
   - If it has a real cert, `certbot renew --cert-name <DOMAIN>` renews only if due.
   - certbot handles the issue-vs-renew distinction; any failure → exit.
8. **`nginx -s reload`** — pick up the real certs.
9. **Background loop** — `( while sleep 12h; do certbot renew --deploy-hook "nginx -s reload"; done ) &`
10. **Signal handling** — trap `TERM`/`INT` → `nginx -s stop`, then `wait`.
11. **Block** — `wait "$NGINX_PID"` (PID 1 stays alive on nginx).

### Domain extraction

From each enabled site config: collect `server_name` tokens, and for each
`ssl_certificate /etc/letsencrypt/live/<DOMAIN>/fullchain.pem` line, derive `<DOMAIN>` as the
path segment between `/live/` and `/`. The domain set = the set of domains found in
ssl_certificate paths (these are the domains certbot will manage).

### Self-signed placeholder

```
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/letsencrypt/live/<DOMAIN>/privkey.pem \
  -out /etc/letsencrypt/live/<DOMAIN>/fullchain.pem \
  -subj "/CN=<DOMAIN>" -days 1
```

## Site config contract

Users drop regular `.conf` files in `sites-available/`. Each file references the LE live path
and includes the ACME snippet in its HTTP server so HTTP-01 challenges resolve:

```nginx
server {
    listen 80;
    server_name mini-2.tongyi.cn;
    include /etc/nginx/includes/acme.conf;
}
server {
    listen 443 ssl;
    server_name mini-2.tongyi.cn;
    ssl_certificate     /etc/letsencrypt/live/mini-2.tongyi.cn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mini-2.tongyi.cn/privkey.pem;

    location / { proxy_pass http://127.0.0.1:8080; }   # example
}
```

`includes/acme.conf`:
```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
    default_type "text/plain";
}
```

The entrypoint keys cert management off the `ssl_certificate … /live/<DOMAIN>/…` path, so the
domain is always derivable from the config — no separate domain list needed.

## Files delivered

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM nginx:1.27-bookworm`, install certbot, copy config + entrypoint, `ENTRYPOINT ["/entrypoint.sh"]` |
| `compose.yml` | service `nginx-router`, ports 80/443, bind `./sites-available`, named volume for `/etc/letsencrypt`, env `CERTBOT_EMAIL` + `USE_STAGING` |
| `build.sh` | `docker compose build` |
| `run.sh` | `docker compose up -d`; errors if `CERTBOT_EMAIL` unset |
| `entrypoint.sh` | algorithm above |
| `nginx/nginx.conf` | base config with `include /etc/nginx/sites-enabled/*` |
| `nginx/includes/acme.conf` | webroot location |
| `sites-available/example.conf` | reference site config |
| `README.md` | usage + the site-config contract |

## Error handling

- Missing `CERTBOT_EMAIL` → exit before touching certs.
- `nginx -t` failure → exit (container stops).
- certbot issuance/renewal failure → exit (container stops).
- `compose.yml` does **not** set `restart: unless-stopped`, so failures are visible, not
  silently re-tried (per spec "exit if any exception was raised").

## Verification

- `docker compose run --rm nginx-router nginx -t` — config validates.
- After start: `ls /etc/letsencrypt/live/<DOMAIN>/` shows real certs.
- `curl -k https://<DOMAIN>/` reaches the proxied backend.
- `docker compose logs nginx-router` shows certbot success + nginx reload.
- Optional `scripts/verify.sh` smoke-check script.
