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

### Publishing a SPA image

`spa` serves the built files on port 80, answering unknown paths with `index.html`,
and contains `wget`. `nginx:alpine`, or `caddy:alpine` with a `try_files …
/index.html` rule, both do. The API URL is usually baked in at build time, so pass
it as a build argument.

### Publishing a server-rendered image

`node-ssr` listens on `0.0.0.0:3000`, answers `/` with 200, and contains `wget`
(any alpine Node image does). Runtime variables go in
`/srv/secrets/<project>/<component>.env`.

### laravel-api and nestjs-api

Their own `Dockerfile` and `publish-image.yml`, as shipped.

## TLS modes

`TLS_MODE` in `/srv/edge/edge.env`:

| Mode | Use | Needs |
|---|---|---|
| `acme` (default) | Let's Encrypt, issued and renewed automatically | Ports 80 and 443 reaching the server |
| `cloudflare` | Behind Cloudflare's proxy. Only Cloudflare's ranges may connect, which is what makes `CF-Connecting-IP` trustworthy | `origin.pem`, `origin.key` and `cf-origin-pull-ca.pem` in `/srv/edge/certs`; SSL mode Full (strict); Authenticated Origin Pulls on |
| `internal` | Local testing only | — |

### Cloudflare mode

Put the three certificate files in `/srv/edge/certs` and set `TLS_MODE=cloudflare`
in `/srv/edge/edge.env`, then run `katap edge up`. After switching to or from
`cloudflare`, update a nestjs-api's `TRUST_CLOUDFLARE_HEADERS` by hand: it reflects
the mode at the time its secrets were generated.

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
