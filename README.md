# nginx-router

nginx + certbot in one container, with externally-editable routing configs and
automatic Let's Encrypt certificate issuance/renewal.

## Quick start

1. Put your site configs (regular `.conf` files) in `sites-available/`.
   See `examples/example.conf` for the contract.
2. Create a `.env` file (loaded by `compose.yml` via `env_file`):

   ```
   CERTBOT_EMAIL=you@example.com
   # USE_STAGING=1   # uncomment while testing to avoid LE rate limits
   # USE_CERTBOT=0   # uncomment to disable certbot entirely (manual certs)
   ```

   Unset vars fall back to the entrypoint defaults (`USE_CERTBOT=1`,
   `USE_STAGING=0`). `CERTBOT_EMAIL` is required only while `USE_CERTBOT=1`.

3. Build and run:

   ```bash
   ./build.sh
   ./run.sh
   ```

The container runs with `network_mode: host`, so nginx and certbot bind
directly to the host's interfaces (ports 80 and 443, plus any `listen`
ports you add in site configs). No port mapping is used.

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
| `./letsencrypt` | `/etc/letsencrypt` | Cert state (live + archive + renewal + accounts). Editable from the host — drop your own certs here (see Manual certs) |
| `./logs` | `/var/log/nginx` | Access/error logs |

## Manual certs

To use your own certificates instead of (or alongside) Let's Encrypt, place
them on the host under `./letsencrypt/live/<DOMAIN>/`:

```
./letsencrypt/live/<DOMAIN>/fullchain.pem
./letsencrypt/live/<DOMAIN>/privkey.pem
```

matching the `ssl_certificate` path in your site config. On start, the
entrypoint detects existing cert files and leaves them untouched — it neither
overwrites them nor asks certbot to issue/renew for that domain. Domains
without cert files are still issued/renewed by certbot as usual (unless
certbot is disabled entirely — see `USE_CERTBOT` below).

To place certs into a running container instead, the directory is the same
bind mount, so you can edit files on the host and run
`docker compose exec nginx-router nginx -s reload`.

## Environment

| Var | Required | Purpose |
|---|---|---|
| `CERTBOT_EMAIL` | when `USE_CERTBOT=1` | Let's Encrypt account email |
| `USE_STAGING` | no | `1` uses the LE staging endpoint (untrusted certs, no rate limits) |
| `USE_CERTBOT` | no | `1` (default) enables certbot issuance/renewal; `0` disables all certbot activity (manual mode — you must provide certs for every SSL domain) |

## How it works

On start the entrypoint:

1. Symlinks every file in `sites-available/*` into `sites-enabled/`.
2. (Only when `USE_CERTBOT=1`.) For each domain referenced by an
   `ssl_certificate` path with no cert files on disk, writes a 1-day
   self-signed placeholder so nginx can boot. Domains with existing cert
   files (managed or manually placed) are left as-is.
3. Runs `nginx -t`, then starts nginx in the foreground (PID 1). With
   `USE_CERTBOT=0`, every SSL domain must already have cert files or
   `nginx -t` will fail and the container will exit.
4. (Only when `USE_CERTBOT=1`.) For each domain: if no cert files exist,
   runs `certbot certonly --webroot` (issue); if certbot-managed, runs
   `certbot renew --cert-name <DOMAIN>` (renews if due); if manually
   placed, skips certbot entirely.
5. (Only when `USE_CERTBOT=1`.) Reloads nginx to pick up real certs.
6. (Only when `USE_CERTBOT=1`.) Starts a background loop running
   `certbot renew` every 12h, reloading nginx on each successful renewal.

Any error exits the container (it does not auto-restart), so failures are
visible.
