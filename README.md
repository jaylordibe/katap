# kit — several projects on one server

Run any number of containerized projects — each with its own API, database and
Redis — on one low-cost VPS, behind one reverse proxy with automatic HTTPS.

A **project** is a set of **components**; a component is a container image. The
kit does not care what language or framework built it. It ships templates for:

| Type | For | Brings its own |
|---|---|---|
| `laravel-api` | [jaylordibe/laravel-api](https://github.com/jaylordibe/laravel-api) and forks | API, Horizon worker, scheduler, PostgreSQL (TLS), Redis |
| `nestjs-api` | [jaylordibe/nestjs-api](https://github.com/jaylordibe/nestjs-api) and forks | API with in-process queue worker, PostgreSQL, Redis |
| `spa` | Angular, React, Vue, … built to static files | — |
| `node-ssr` | Next.js, Nuxt, SvelteKit, Remix, … | — |

**Who does what**

| | Does | Holds credentials for |
|---|---|---|
| Application repository | Tests, then builds, scans and publishes its image to GHCR with a provenance attestation (`publish-image.yml`). Never deploys. | Pushing its own image; optionally starting a staging deploy (Actions: write here, nothing else) |
| This repository | Defines the projects (`projects/`), and deploys: `.github/workflows/deploy.yml` verifies the image's attestation and asks the server to run it. | SSH to the server |
| The server | Pulls by digest and runs `kit deploy`. | Reading images |

An application repository can publish an image, and its staging dispatch token can
start the Deploy workflow, which is all an Actions: write token can do here (it can
also cancel or delete runs; it cannot change a file). What that workflow then
deploys is bound: a component belongs to one environment (`environment=` in its
`.conf`), and each host's key serves one environment, so a staging request can never
replace a production component, even on a shared server. A production request still
waits for its reviewers. The Deploy workflow deploys only
digests attested by that repository's own publish workflow (from `main` for
production). That check runs in the workflow: the server itself accepts any digest
of the component's repository from the deploy key, so guard this repository as the
holder of that key (below).

## Is a single server right for this?

Yes, for side projects and low-traffic apps. It is the same model Coolify and Dokku
use. Know the two costs:

- **Shared fate.** One server down means every project is down. Backups (below) are
  what make that recoverable; nothing here makes it highly available.
- **Memory is the limit.** Approximate steady-state RAM per component:

  | Component | RAM |
  |---|---|
  | laravel-api: API (php-fpm, up to 20 workers in the base image) | 150 MB idle, up to ~1 GB (`mem_limit`) |
  | laravel-api: Horizon worker | 100–300 MB |
  | nestjs-api | 150–400 MB |
  | PostgreSQL / Redis (each project) | 50–100 MB / ~10 MB |
  | spa / Caddy | ~10 MB / ~30 MB |

  A 4 GB VPS holds two or three small projects. Lower `mem_limit` in a project's
  compose file to fit more, and move a project to its own server or a managed
  database when it outgrows its share.

## Layout

```
bin/kit                     the CLI (bash 5; runs on the server)
edge/                       the shared Caddy: compose.yml, Caddyfile, edge.env (TLS mode, network)
templates/<type>.*          compose file, deploy settings, secret spec and site block per type
projects/<project>/         YOUR projects: <component>.yml, <component>.conf, site.caddy (no secrets)
host/provision.sh           prepares a server; host/systemd/ holds the timers it installs
lib/                        shared scripts (smoke check, PostgreSQL TLS and app role)
.github/workflows/deploy.yml   the deploy workflow
examples/publish-image.yml  the publish workflow an application repository copies
tests/run.sh                the kit's tests (E2E=1 for a real deploy on local Docker)
```

On the server (`/srv`): `kit/` (this repository), `secrets/<project>/` (0700, never
in git), `state/<project>/` (what is deployed, and the history), `backups/<project>/`,
`edge/certs/` (Cloudflare mode only).

## Setting up a server

1. **A fresh Ubuntu 24.04 (or Debian 12) VPS**, with your SSH key on it.
2. Clone and provision:

   ```bash
   sudo git clone https://github.com/<you>/cicd.git /srv/kit
   # on your machine: one CI key per environment this server hosts
   ssh-keygen -t ed25519 -N '' -f ci_production
   ssh-keygen -t ed25519 -N '' -f ci_staging
   sudo /srv/kit/host/provision.sh --ci-key "$(cat ci_production.pub)" --ci-env production --harden-ssh
   sudo /srv/kit/host/provision.sh --ci-key "$(cat ci_staging.pub)" --ci-env staging
   ```

   It installs Docker, sets log rotation, a firewall (22, 80, 443), unattended
   security upgrades, a swap file, the `deploy` user, the per-minute and nightly
   timers, and starts the edge. It is safe to run again.
3. **Private images:** log the deploy user in with a token that can only read packages:
   `sudo -u deploy docker login ghcr.io -u <user> --password-stdin`.

## Adding a project

In your copy of this repository:

```bash
bin/kit add shop laravel-api api api.shop.com
bin/kit add shop spa web shop.com www.shop.com
```

Then, in `projects/shop/api.conf` and `web.conf`, set `image=` (e.g.
`ghcr.io/you/shop-api`) and `source_repo=` (`you/shop-api`); a `nestjs-api` also
needs `image_migrate=`. Components are `environment=production` by default; a
staging copy of a project is its own project (`shop-staging`) with
`environment=staging`. Review the copied compose files — they are yours to edit
(memory limits, an extra worker). Run `bin/kit check shop`, commit, push.

On the server, as the deploy user:

```bash
cd /srv/kit && git pull
bin/kit secrets shop api        # once: APP_KEY, Passport keys, database and Redis passwords
bin/kit secrets shop web
nano /srv/secrets/shop/api.env  # fill every value under '# kit:required', add mail/storage settings
```

`kit secrets` never overwrites: it refuses if the files exist. Point the project's
DNS at the server; Caddy obtains certificates on the first request.

## Publishing and deploying

**In each application repository:**

- `laravel-api` and `nestjs-api` ship `.github/workflows/publish-image.yml`. It does not know about this kit; to have a staging push start a deploy here, add the dispatch step from `examples/publish-image.yml`.
- For anything else, copy `examples/publish-image.yml` to that path. The path matters: the deploy verifies the attestation came from it.

Set the repository variable `PUBLISH_ENABLED=true`. Every push to `main` or `staging` then:

1. runs the repository's gates (laravel-api skips its test suite on `staging`, by design);
2. pushes `ghcr.io/<owner>/<repo>:sha-<commit>`;
3. scans that digest, attests its provenance, and only then moves `:<branch>`.

**Attestations need a public repository**, or a GitHub plan that offers them on
private ones (then set `ATTEST_PROVENANCE=true`). For a private repository without
them, set `provenance=none` in the component's `.conf`: the Deploy workflow then
trusts anything pushed to that image repository, and says so on every run.

### Securing the deploy path (required)

This repository's code holds the deploy keys: whoever can change `main` can deploy
anything to any host. Before adding secrets:

1. **Ruleset on `main`** (Settings → Rules): require a pull request, block force
   pushes and deletion, and allow **no bypass**, not even for yourself.
2. **Deployment branches**: each environment accepts `main` only.
3. **Required reviewers on production.**
4. The staging dispatch token in an application repository is fine-grained with
   **only Actions: write** on this repository.

**In this repository**, create the environments `production` and `staging` (Settings →
Environments), each with:
- the secrets listed at the top of `.github/workflows/deploy.yml`;
- for production, **required reviewers**.

Get `DEPLOY_KNOWN_HOSTS` once, from the server itself:
`ssh-keyscan -t ed25519 localhost | sed "s/^localhost/<server>/"`.

**Deploy:** Actions → Deploy → Run workflow → environment, project, component, image
(`ghcr.io/you/shop-api:main`, resolved to its digest before anything runs; for a
nestjs-api the same tag names its migrate image). A `staging` push can also start
its own staging deploy (`DEPLOY_DISPATCH_*` in `examples/publish-image.yml`); production
always waits for its reviewers. The host refuses a request resolved against a
different commit of this repository than its own checkout, so `git pull` on the
server after merging project changes.

What `kit deploy` does on the server, in order:

1. Validates the digest against the component's `image=`, and refuses an empty required secret.
2. Pulls the image. On failure nothing has changed.
3. Dumps the database (pre-deploy, kept with the nightly dumps).
4. Runs the one-shots: `migrate`, then `permissions` (Laravel); `migrate` (Nest: prisma deploy + rbac:sync). If one fails, the current release keeps serving.
5. Recreates the services in order (Laravel: worker, then API) and waits for their healthchecks. Caddy holds requests across the swap.
6. Smoke-checks the component from inside the project network. If unhealthy, it **rolls back** to the previous release automatically.
7. Records the release, and reloads the edge. A site file that fails to load is a
   warning: the release is serving, the edge keeps its previous configuration.

The workflow then checks the public URL with the same smoke check. The deploy runs
detached on the host: a cancelled workflow or a dropped connection never stops it
half-way (its log is in `/srv/state/dispatch/`).

**First deploy only:**
- **laravel-api:** create the Passport personal access client (sign-in needs it), and your first admin:
  ```bash
  bin/kit run shop api-artisan passport:client --personal --name='API Personal Access Client' --provider=users --no-interaction
  ```
  Never run `db:seed` or `UserSeeder` in production: it creates test users with a published password.
- **nestjs-api:** `bin/kit run blog api-migrate yarn prisma:seed` creates the admin from `SEED_ADMIN_*`.

## Day to day

| Task | Command (on the server, as `deploy`) |
|---|---|
| Roll back to the previous release | `bin/kit rollback shop api`: the release deployed before the one serving, and again for the one before that. A named digest must be one this host has deployed. Never runs migrations backwards: keep them expand-only |
| A one-off command | `bin/kit run shop api-artisan <artisan args>` — as the application user, never root |
| Long scheduled work | each project's per-minute run is cut off after 10 minutes (`KIT_CRON_TIMEOUT`), below the 15 a deploy waits for it: put long work on the queue |
| Logs | `docker compose -p shop logs -f api` |
| Status | `docker compose -p shop ps` |
| Back up now | `bin/kit backup shop` (nightly by timer; keeps 14 of each kind per component, `KIT_BACKUP_KEEP`: nightly, pre-deploy and pre-restore are counted apart) |
| Off-host copies | install rclone, set `KIT_RCLONE_REMOTE=remote:bucket/path` in `/etc/kit/kit.env`; use an rclone `crypt` remote, the dumps hold personal data |
| Restore | `bin/kit restore shop api /srv/backups/shop/<file>.dump --confirm shop` (see below) |
| Change a site or add a domain | edit `projects/<project>/site.caddy`, pull, `bin/kit edge reload` |
| Change the TLS mode | edit `edge/edge.env`, pull, `bin/kit edge up` |

**Restore** puts back the database **and the release that was serving when the dump
was taken** (recorded beside each dump as `<dump>.images`). It stops the component,
dumps the current data, restores into a new database and swaps it in only when
complete, so a failed restore changes nothing. It also empties the component's
Redis: queued jobs and caches (permissions, sessions) described the replaced data.
Tokens issued after the dump work again, because the keys did not change.

**Test a restore** before you need one: a backup that has never been restored is a
hope, not a backup. Keep a copy of `/srv/secrets` somewhere safe too: a dump without
its `APP_KEY` cannot decrypt what the application encrypted.

**Upgrading PostgreSQL** (a new major in a template's image), never with the
application serving in between:

1. `docker compose -p <project> stop <component> <component>-worker` (its rollout services);
2. `bin/kit backup <project>`;
3. change the image in `projects/<project>/<component>.yml`, commit, pull;
4. `docker volume rm <project>_<component>-db`;
5. `docker compose -p <project> up -d <component>-db` (the database alone);
6. `bin/kit restore <project> <component> <that dump> --confirm <project>`, which
   restores the data and starts the release again.

The database refuses to start an empty cluster beside an old one, so a forgotten step
stops the database rather than serving an empty one.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `kit deploy` refuses: required values are empty | A `# kit:required` value in the component's secrets is blank | `/srv/secrets/<project>/<component>.env` |
| A deploy fails and rolls back | The new release never became healthy, or its smoke check failed | `docker compose -p <project> logs --tail=200 <service>` |
| `502` from the edge | The upstream container is down or unhealthy | `docker compose -p <project> ps` |
| No certificate (acme mode) | DNS does not point at the server yet, or 80/443 are blocked upstream | `docker compose -p kit-edge logs caddy` |
| `525`/`526` from Cloudflare | Origin certificate missing or wrong, or Authenticated Origin Pulls off | `ls -l /srv/edge/certs`, the Cloudflare dashboard |
| Every client shares one IP (per-IP limits act globally) | The application does not trust the edge's address | nestjs-api: `TRUST_PROXY` equals `CADDY_IP`; laravel-api: `TRUSTED_PROXIES=0.0.0.0/0` |
| API logs `ECONNREFUSED` to its database | The database is still starting, or restarting | `docker compose -p <project> logs <component>-db` |
| Disk filling up | Old images | `docker image prune` (logs are already capped) |

## The project contract

`kit check` enforces it, and `kit deploy` refuses a project that breaks it:

- **No `ports:` anywhere.** Only the edge publishes ports. Docker-published ports
  bypass the firewall, so this rule is what keeps databases off the internet.
- **Every image is pinned by digest.** Application images come from the deploy, as
  `${IMAGE_<COMPONENT>}`.
- **Every long-running service has a healthcheck.** That is what `--wait` and the
  automatic rollback rely on.
- **One-shot services** are in the `predeploy`, `cron` or `tools` profile, and never
  restart.
- **Databases never join the `edge` network.**
- **Never privileged, host networking, the host PID namespace, or the Docker socket.**
- **No fixed `hostname:`.**
- **Every service a `.conf` names exists.**

## Publishing an image: what each type expects

- **spa:**
  - Serves the built files on port 80, answering unknown paths with `index.html`.
  - Contains `wget`. `nginx:alpine` or `caddy:alpine` with a `try_files … /index.html` rule both do.
  - The API URL is usually baked in at build time, so pass it as a build argument in the SPA's publish workflow.
- **node-ssr:**
  - Listens on `0.0.0.0:3000` and answers `/` with 200.
  - Contains `wget` (any alpine Node image does).
  - Runtime variables go in `/srv/secrets/<project>/<component>.env`.
- **laravel-api / nestjs-api:** their own `Dockerfile` and `publish-image.yml`, as shipped.

## TLS: `edge/edge.env`

- **`acme`** (default): Let's Encrypt, issued and renewed automatically. Ports 80 and 443 must reach the server.
- **`cloudflare`**: behind Cloudflare's proxy, with an Origin Certificate and Authenticated Origin Pulls.
  - Put `origin.pem`, `origin.key` and Cloudflare's `cf-origin-pull-ca.pem` in `/srv/edge/certs`.
  - Set SSL mode Full (strict) and turn Authenticated Origin Pulls on.
  - Only Cloudflare's ranges may connect, which is what makes `CF-Connecting-IP` trustworthy.
  - You do not re-run `kit secrets` after a switch. A nestjs-api's `TRUST_CLOUDFLARE_HEADERS` reflects the mode at the time its secrets were generated, so update that one value by hand if you switch.
- **`internal`**: Caddy's own CA, for local testing only.

## Trusted proxies

Every request reaches an application from Caddy's fixed address on the `edge`
network (`CADDY_IP`). Caddy replaces any `X-Forwarded-For` a client sends with the
address it actually saw.
- **nestjs-api** trusts exactly `CADDY_IP` (`TRUST_PROXY`).
- **laravel-api** is given `TRUSTED_PROXIES=0.0.0.0/0`, deliberately: its base image's nginx and Laravel parse that variable differently, and a single all-addresses CIDR is the only value both accept while keeping the real client address and HTTPS detection. Nothing outside the host can reach the API container (the contract above). Public components of other projects on the same edge network can, which is accepted under Known limits.

## Security model

- **Exposure:** only 22, 80 and 443 are open; only Caddy publishes. Each project's database and Redis sit on that project's private network: another project cannot even resolve their names.
- **Secrets:** generated once on the server (`openssl`), 0600, outside git; never regenerated. The database superuser password stays in `<component>.db.env`, which only the database container reads. The application connects as a non-superuser role owning its database.
- **Deploys:** images are pinned by digest, scanned, and provenance-verified by the Deploy workflow. Each CI key's `authorized_keys` entry is `restrict,command="kit ssh-dispatch <environment>"`, so it can deploy, or roll back to a release the host has served, only components of its own environment, with validated arguments, and do nothing else. The workflow's own code is protected by the ruleset above.
- **Destructive operations:** none are automated. No path drops a volume, regenerates a key or runs a fresh migration. `restore` is human-only and dumps first.

**Known limits.** These are accepted as residual risk:
- IPv4 only: the edge publishes no IPv6 port (an IPv6 client would reach every site with the same address). Publish no AAAA record.
- The `deploy` user is in the `docker` group, which is root-equivalent on the host. Protect its keys.
- Public components of different projects share the `edge` network, so one could call another's public service directly, and a laravel-api trusts any address there to set the client IP (`TRUSTED_PROXIES`). They cannot reach databases.
- laravel-api's database link uses `sslmode=require`: encrypted, but the certificate is not verified. The traffic never leaves the host.
- Have a person review this repository's deploy path before trusting it with real data. Automated tests do not replace that review.

## Testing the kit

```bash
tests/run.sh          # shellcheck, the contract, secrets, refusals, ssh-dispatch, smoke check, edge config
E2E=1 tests/run.sh    # plus a real deploy on local Docker: build laravel-api, deploy, roll back, back up, restore
```

Both run inside a pinned Linux container (`tests/runner.Dockerfile`), so a Mac's
bash 3.2 behaves exactly like the server.
