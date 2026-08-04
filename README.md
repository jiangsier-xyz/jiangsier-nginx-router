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
