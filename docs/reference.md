# Reference

## Commands

`/srv/katap/bin/katap help` prints them all; the list lives at the top of
[`bin/katap`](../bin/katap). Run them as the deploy user.

## Layout

```text
install.sh                     the one-line installer (served from main; installs a release)
connect.sh                     connects application repositories (runs on your computer)
bin/katap                      the CLI (bash 5; runs on the server)
action.yml, action/            the deploy action applications use
edge/                          the shared Caddy: compose.yml, Caddyfile, edge.env (defaults)
templates/<type>.*             compose file, deploy settings, secret spec and site block per type
host/provision.sh              prepares a server; host/systemd/ holds its timers
lib/                           smoke check, PostgreSQL entrypoint, TLS and app role
examples/                      publish-image.yml and deploy.yml for application repositories
tests/                         static, unit and end-to-end tests
```

On the server:

| Path | Holds |
|---|---|
| `/srv/katap` | The tool, root's, at a release's commit |
| `/srv/katap.json` | Which projects the server runs ([The projects file](projects-file.md)) |
| `/srv/projects/<project>/` | Each project's compose files, `.conf` files and `site.caddy` |
| `/srv/secrets/<project>/` | Generated secrets (0700) |
| `/srv/state/<project>/` | What is serving, and the history |
| `/srv/backups/<project>/` | Database dumps |
| `/srv/edge/` | This server's `edge.env` and Cloudflare certificates |
| `/etc/katap/katap.env` | Host settings: the GitHub token, backup and timing options |
| `/etc/katap/release` | The installed release (`tag=`, `commit=`) |

## The project contract

`katap check` enforces it, and `katap deploy` refuses a project that breaks it:

- **No `ports:` anywhere.** Docker-published ports bypass the firewall, so this is what keeps databases off the internet.
- **Every image pinned by digest.** Application images come from the deploy, as `${IMAGE_<COMPONENT>}`.
- **Every long-running service has a healthcheck**, which the rollout and the automatic rollback rely on.
- **One-shot services** sit in the `predeploy`, `cron` or `tools` profile and never restart.
- **Databases never join the edge network.**
- **Never privileged**, host networking, the host PID namespace or the Docker socket.
- **No fixed `hostname:`**, and every service a `.conf` names exists.
- **The `.conf` agrees with `/srv/katap.json`** for every component it declares.

## What each template expects from an image

Every application repository needs:
- **Its own `Dockerfile`.** Katap and `examples/publish-image.yml` don't create one.
- **The publish workflow at exactly `.github/workflows/publish-image.yml`.** The server checks that the attestation was signed by that path, and refuses any other.
- **Real tests in that workflow.** The example's `test` job only prints a message, so replace it.

| Template | Must serve | Healthcheck needs | Smoke check |
|---|---|---|---|
| `spa` | Port 80; unknown paths answered with `index.html` | `wget` in the image | `GET /` returns 200, with no redirect |
| `node-ssr` | `0.0.0.0:3000` | `wget` in the image | `GET /` returns 200, with no redirect |
| `laravel-api`, `nestjs-api` | As their starter repositories define | The starter's own | The starter's readiness endpoint |

Katap's checks only request `/`. They don't prove that client-side routes such as
`/orders/42` fall back to `index.html`, so test that yourself.

### Publishing a SPA image

`spa` serves the built files on port 80, answers unknown paths with `index.html`,
and contains `wget`. Both `nginx:alpine` with a fallback rule and `caddy:alpine`
with a `try_files … /index.html` rule work. `/` must answer 200 itself, not
redirect, because the smoke check follows no redirects.

### Publishing a server-rendered image

`node-ssr` listens on `0.0.0.0:3000`, answers `/` with 200 without a redirect, and
contains `wget` (alpine-based Node images do). Katap's generated settings set
`PORT=3000` and `HOSTNAME=0.0.0.0`. Other runtime variables go in
`/srv/secrets/<project>/<component>.env`; see [Application settings](projects-file.md#application-settings).

### laravel-api and nestjs-api

Use their own `Dockerfile` and `publish-image.yml`, as shipped. A `nestjs-api`
component also needs the `-migrate` image that its workflow publishes alongside.
An arbitrary Laravel or NestJS image doesn't meet these templates' contracts.

### Build-time and runtime settings

- **A static SPA** has no server process to read settings, so values such as the API's address are fixed when the image is built. Pass them as build arguments in `publish-image.yml`. A change means a new build.
- **A server-rendered app or an API** reads runtime settings from its `.env` file on the server. A change means a new deploy: see [Application settings](projects-file.md#application-settings).

A generic example. The variable names are placeholders: use the names your
application's build actually reads.

```yaml
# .github/workflows/publish-image.yml, in the "Build and push" step
        with:
          context: .
          build-args: |
            PUBLIC_API_URL=https://api.example.com
```

```dockerfile
# Dockerfile (excerpt)
FROM <your build image> AS build
ARG PUBLIC_API_URL
ENV PUBLIC_API_URL=$PUBLIC_API_URL
RUN <your build command>        # reads PUBLIC_API_URL while building

FROM <your static file server image>
COPY --from=build <your build output> <the server's web root>
```

A build argument ends up in the image, so never pass a secret this way.

## DNS records

*Where: your DNS provider.*

- **One A record per domain**, pointing at the server's IPv4 address. `katap apply` prints the list. Every name a component serves must be in its `domains` in `katap.json`.
- **No AAAA records.** The edge listens on IPv4 only, so IPv6 visitors would fail.
- **`www`:** either its own A record, or a CNAME such as `www.example.com → example.com`. A CNAME only points DNS somewhere; it's not an HTTP redirect. The server must still serve `www`, which needs one of these:
  - list `www.example.com` in the component's `domains`, so it's served directly with its own certificate;
  - or list only one name there and add a redirect block for the other to `site.caddy`. The `spa` template's site block shows one.

**Check:** `dig +short A example.com` prints `203.0.113.10` for a DNS-only record.
A Cloudflare-proxied record prints Cloudflare's addresses instead.

## TLS modes

`TLS_MODE` in `/srv/edge/edge.env`:

| Mode | Use | Needs |
|---|---|---|
| `acme` (default) | Let's Encrypt (or ZeroSSL), issued and renewed automatically | DNS pointing at the server; ports 80 and 443 reaching it from the internet |
| `cloudflare` | Behind Cloudflare's proxy. Only Cloudflare's ranges may connect, which is what makes `CF-Connecting-IP` trustworthy | `origin.pem`, `origin.key` and `cf-origin-pull-ca.pem` in `/srv/edge/certs`; SSL mode Full (strict); Authenticated Origin Pulls on |
| `internal` | Local testing only | — |

**With Cloudflare, choose one of these setups:**

| Cloudflare record | `TLS_MODE` | Status |
|---|---|---|
| DNS only (grey cloud) | `acme` | The default. Visitors reach Caddy directly |
| Proxied (orange cloud) | `cloudflare` | Supported; see [Cloudflare mode](#cloudflare-mode) |
| Proxied (orange cloud) | `acme` | **Not supported.** Katap doesn't configure or test it |

The last setup has two problems you can see in `edge/Caddyfile`:
- applications see Cloudflare's addresses as every client's address;
- the server still accepts direct connections that bypass Cloudflare.

Whether certificates can be issued through the proxy depends on your Cloudflare
settings (**unverified**). Turning on the orange cloud doesn't switch Katap to
Cloudflare mode; only `TLS_MODE` does.

**Checking HTTPS at the server, bypassing DNS and any proxy** (`acme` mode), from
your computer:

```bash
curl -sSI --resolve example.com:443:203.0.113.10 https://example.com/
```

A `200` status with no certificate error means the server's own certificate is valid.

### Cloudflare mode

In this mode, Caddy:
- serves a Cloudflare Origin CA certificate;
- refuses TLS connections without Cloudflare's client certificate (Authenticated Origin Pulls);
- drops connections from outside Cloudflare's IPv4 ranges;
- takes the client's address from `CF-Connecting-IP`.

1. *Cloudflare dashboard:* set **SSL/TLS** encryption mode to **Full (strict)**.
2. *Cloudflare dashboard:* create an origin certificate under **SSL/TLS → Origin Server → Origin Certificates → Create Certificate**. Cover every domain the server serves and choose the PEM format. Save the certificate as `origin.pem` and the private key as `origin.key`. Cloudflare shows the key only once. Browsers don't trust this certificate: only Cloudflare does. Cloudflare doesn't send expiry reminders for it.
3. *Cloudflare dashboard:* download the Authenticated Origin Pulls CA certificate (the [`authenticated_origin_pull_ca.pem`](https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem) file Cloudflare's documentation links), and save it as `cf-origin-pull-ca.pem`. Then turn on **SSL/TLS → Origin Server → Authenticated Origin Pulls → Global**.
4. *Server SSH session:* create the three files in `/srv/edge/certs` as the deploy user, for example `sudo -u deploy nano /srv/edge/certs/origin.key`. Then lock down the key: `sudo -u deploy chmod 600 /srv/edge/certs/origin.key`.
5. *Server SSH session:* set `TLS_MODE=cloudflare` in `/srv/edge/edge.env` (`sudo -u deploy nano /srv/edge/edge.env`), then run `sudo -u deploy /srv/katap/bin/katap edge up`.
6. *Cloudflare dashboard:* switch the DNS records to **Proxied**.

After switching to or from `cloudflare`, update a nestjs-api's
`TRUST_CLOUDFLARE_HEADERS` by hand: it reflects the mode at the time its secrets
were generated.

**Checks.** Each one proves one thing. A failed connection only counts as evidence
when it fails for the expected reason.

1. **Through Cloudflare** (*your computer*): `curl -sSI https://example.com/` returns a `200` status, with a `server: cloudflare` and a `cf-ray` header. This proves visitors get HTTPS from Cloudflare. It doesn't prove Cloudflare reached your origin, or that its client certificate was accepted: Cloudflare can answer from its cache (`CF-Cache-Status: HIT`) without contacting the origin.

   Evidence of an origin request needs a request you can see arrive. Choose an endpoint your Cloudflare cache settings don't cache (by default Cloudflare doesn't cache HTML or JSON, but Cache Rules can change that), request it through Cloudflare, and find that request in the application's logs at the same time (`docker compose -p <project> logs --since 5m <component>`). Katap's edge doesn't log requests itself. A random query string, a `Cache-Control` request header or a response header alone doesn't guarantee the origin was contacted.
2. **The network path to the origin** (*your computer*):
   ```bash
   nc -vz -w 5 203.0.113.10 443
   ```
   `succeeded` (or `open`) means nothing in the network blocks you, so the checks below test Caddy. A timeout or `refused` means a firewall or a stopped edge. That's not evidence that origin pulls work.
3. **The origin certificate and its names** (*your computer*). Origin CA certificates aren't trusted by browsers or `curl` by default, so a plain `curl` to the origin always fails with a certificate error, exit code 60. That failure proves nothing. Trust Cloudflare's Origin CA root explicitly instead:
   - [`origin_ca_rsa_root.pem`](https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem) for an RSA origin certificate;
   - [`origin_ca_ecc_root.pem`](https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem) for an ECC one.

   This is a different file from the Authenticated Origin Pulls certificate. Keep the hostname, so SNI and name checking still apply:
   ```bash
   openssl s_client -connect 203.0.113.10:443 -servername example.com \
       -CAfile origin_ca_rsa_root.pem -verify_hostname example.com < /dev/null 2>&1 | grep 'Verify return code'
   ```
   `Verify return code: 0 (ok)` proves the origin presents a valid Origin CA certificate for `example.com`. Anything else names the problem: an unknown issuer means the wrong root or certificate; a hostname mismatch means the certificate doesn't cover that name.
4. **Origin pulls enforced** (*your computer*). Same trust and name, but now as an HTTP request:
   ```bash
   curl -sS -o /dev/null --cacert origin_ca_rsa_root.pem \
       --resolve example.com:443:203.0.113.10 https://example.com/; echo "exit $?"
   ```
   - **Expected:** the server certificate is accepted (no exit code 60), then the request fails with a TLS alert for a missing client certificate. On OpenSSL builds it reads `alert certificate required`; others show alert code 1116. The exit code is usually 56 or 35. That proves Caddy demands a client certificate before serving anything.
   - **A `200`** means origin pulls aren't enforced: check `TLS_MODE` and `katap edge up`.
   - **Exit code 60** means step 3 hasn't passed yet.
   - **A connection failure (exit code 7 or 28)** is the network, not origin pulls.
5. **Non-Cloudflare addresses are dropped.** Caddy also drops any request whose source isn't in Cloudflare's ranges, but only after the TLS handshake. Without Cloudflare's client certificate you can't get that far, so this layer can't be tested from outside. Check the setting instead (*server*): `sudo -u deploy grep '^TLS_MODE=' /srv/edge/edge.env` prints `TLS_MODE=cloudflare`.

On the server, check the certificate's names and expiry:
`openssl x509 -in /srv/edge/certs/origin.pem -noout -subject -enddate -ext subjectAltName`.

Never use `curl -k` or `--insecure` as a check, or as configuration: it hides exactly
what step 3 tests. Error wording varies with the TLS library; the exit codes above
come from a local test against the same Caddy settings, not from a real Cloudflare
zone.

**Limits:**
- Global Authenticated Origin Pulls uses a certificate shared by every Cloudflare account. It proves a request came through Cloudflare, not through your zone. Zone-level pulls with your own CA certificate are stricter, but they're **not tested with Katap**.
- Cloudflare's IPv4 ranges are written into `edge/Caddyfile` and change only with a Katap release.
- Port 22 still needs direct access for SSH and deploys: Cloudflare's proxy carries only web traffic.

## Trusted proxies

Every request reaches an application from Caddy's fixed address on the edge
network (`CADDY_IP`). Caddy replaces any client-sent `X-Forwarded-For` with the
address it actually saw.

- **nestjs-api** trusts exactly `CADDY_IP` (`TRUST_PROXY`).
- **laravel-api** gets `TRUSTED_PROXIES=0.0.0.0/0`, deliberately. Its base image's nginx and Laravel parse that variable differently, and one all-addresses CIDR is the only value both accept while keeping the real client address and HTTPS detection. Nothing outside the server can reach the API container.

## Testing Katap

```bash
tests/run.sh          # shellcheck, the contract, secrets, apply, provenance, ssh-dispatch, the action, install.sh, connect.sh, provisioning, smoke check, edge
E2E=1 tests/run.sh    # plus a real deploy on local Docker: build laravel-api, apply, deploy, roll back, back up, restore
```

Both run inside a pinned Linux container (`tests/runner.Dockerfile`), so a Mac's
bash 3.2 behaves exactly like the server.
