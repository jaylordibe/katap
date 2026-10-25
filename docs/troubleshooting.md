# Troubleshooting

## Installing and setting up

| Symptom | Likely cause | Check |
|---|---|---|
| install: no published release | GitHub has no Release for Katap | Pass `--version vX.Y.Z` |
| install: … of another major version, which changes how deploys work | The latest release is of another major version than the server runs | Read [Updating Katap](updating.md), then pass `--version` with that release |
| install: … a Katap checkout with no release record | `/srv/katap` has no `/etc/katap/release` and is not at a release tag | Read [Updating Katap](updating.md), then pass `--version` |
| install: has local changes | Files under `/srv/katap` were edited or added | `git -C /srv/katap status`; see [Updating Katap](updating.md#what-the-installer-refuses) |
| apply: no /srv/katap.json | The projects file is missing | Write it; see [The projects file](projects-file.md) |
| apply: no terminal to confirm on | apply has something to create or change, and nothing to ask on | Run it in a terminal, or `katap apply --yes` |
| apply: … provenance is no longer a setting | A v1 `katap.json` | Delete `"provenance"` from that component |
| apply: … is claimed by both | One domain is listed for two components | Each domain belongs to one component, across every project |
| apply: a value contains whitespace or a control character | A pasted value carries a space, tab or line break | Edit the value; lists such as `domains` are JSON arrays |
| apply: … still serves | A domain moves to another component before its old site block is gone | See "Moving a domain" in [The projects file](projects-file.md#what-stays-yours) |
| deploy-key: already has a … deploy key | The component has a key | `katap deploy-key <project> <component> --replace`, then update the repository's secret |
| deploy-key: set host | `host` is empty in `/srv/katap.json` | Set the server's public IPv4 address there |
| remove: … is in /srv/katap.json | The component is still listed | Delete it from `/srv/katap.json` first |
| remove: … was deployed / has data volumes / has secrets of a component that is not being removed | `katap remove` only removes what never ran, and never another component's files | [Taking a deployed component off the server](projects-file.md#taking-a-deployed-component-off-the-server) |
| apply, deploy-key, remove: run … as the owner of /srv/projects | Run with `sudo` straight from `/srv/katap/bin/katap` | Use the `katap` command, which runs it as the deploy user |

## Deploying

| Symptom | Likely cause | Check |
|---|---|---|
| Deploy refused: required values are empty | A `# katap:required` value is blank | `katap env <project> <component>` |
| Deploy refused: … differs from /srv/katap.json | A `.conf` was edited, or `katap.json` changed without `apply` | `katap apply` |
| Deploy refused: … is not this component's repository | The workflow pushed to another image repository than the component's | `repo` (or `image`) in `/srv/katap.json`, and where the workflow pushes |
| Deploy refused: could not pull … | The image isn't on the server, and the pull failed: a wrong digest, or a private image deployed without the workflow's token | The deploy step's `image`; the deploy job's `permissions: packages: read`. A rollback or restore by hand of a private image no longer on the server: `sudo -u deploy docker login ghcr.io` with a `read:packages` token, then `sudo -u deploy docker logout ghcr.io` |
| laravel-api restarts: TRUSTED_PROXIES must not include a /0 network | A component created before Katap v2, deploying a laravel-api build from commit `0077bff` or later | `katap env <project> <component>`: set `TRUSTED_PROXIES` to `CADDY_IP` from `/srv/edge/edge.env` |
| laravel-api builds `http://` links behind the edge | A laravel-api build from before commit `0077bff`, with `TRUSTED_PROXIES` set to the edge's address | Rebuild from current laravel-api |
| Deploy refused: could not log in to ghcr.io | The job's token could not read the package | The package's access: a package published by the repository's own workflow can be read by its token |
| Deploy refused: standard input must be one line | A server before v2.0.3, which refuses GitHub's current job token; or a modified action, or one from another major version than the server | Run the installer to upgrade the server; pin the step to v2.0.3 or later of your server's major version ([Updating Katap](updating.md)) |
| Action warns: registry-token is not this job's GitHub token | A step before v2.0.3, which does not recognise GitHub's current job token; or `registry-token` set to a personal token | Pin the step to v2.0.3 or later, after the server ([Updating Katap](updating.md)); leave `registry-token` unset and give the job `permissions: packages: read` |
| Deploy refused: this key deploys … only | The repository's `KATAP_PROJECT` or `KATAP_COMPONENT` variable (staging: `KATAP_STAGING_…`) is not the key's | Those variables, as `katap deploy-key` printed them |
| Deploy refused: this key names no project and component | A key added or edited by hand in `authorized_keys` | `katap deploy-key <project> <component> --replace` |
| Deploy refused: … is not in /srv/katap.json, so it no longer deploys | The component was deleted from the projects file, or was made by hand on a server where `katap apply` has run | Add it to the file and `katap apply`, or [take it off the server](projects-file.md#taking-a-deployed-component-off-the-server) |
| Deploy refused: this component also needs migrate= | A nestjs-api deploy job with its `migrate-image` line still commented | Uncomment it in both deploy jobs, as `katap deploy-key` says |
| Deploy refused: … did not finish within 15m (KATAP_PREDEPLOY_TIMEOUT) | A migration waited on a table lock (a long or idle transaction), or ran longer than the limit | Find the blocker in the database (`pg_stat_activity`); a migration that is simply long: raise `KATAP_PREDEPLOY_TIMEOUT` in `/etc/katap/katap.env` |
| Rollback refused: … deploy it instead of rolling back to it | A rollback goes back only, along the releases the database has run: never forward past the release serving, nor to one a restore cut off | Deploy that release instead: a deploy runs its migrations |
| Deploy log: WARNING … keep NET_RAW | A compose file copied from an older template | Add `cap_drop: [NET_RAW]` to each service named; see [Updating Katap](updating.md#from-v1-to-v2) |
| `katap run` refused: … has no release yet | The service's component was never deployed | Deploy it first |
| restore: … is not a dump of '…' | The dump's name starts with another component's | Pick a dump of this component: `/srv/backups/<project>/<component>-…` |
| restore: … renaming it to app failed | The restored data is complete but under another name | Do what the message says: rename the database by hand, then the `katap rollback` it prints |
| Deploy refused: already running, or dispatched less than 60s ago | Another deploy of that component is in progress, or one just finished | Wait, then re-run; its log is in `/srv/state/.dispatch/<project>/` |
| Deploy refused: has local modifications, or is not the release install.sh installed | `/srv/katap` was edited, or moved off the installed release | Run the installer again |
| Action fails: is not on ghcr.io / known-hosts is empty | The image is on another registry, or the `KATAP_KNOWN_HOSTS` secret is missing | Set the action's `registry` input; add the secret `katap deploy-key` printed |
| Action fails: Permission denied (publickey) | The `KATAP_SSH_KEY` secret is not the key the server has, or was pasted without its first or last line | Replace it: `katap deploy-key <project> <component> --replace` |
| Deploy fails and rolls back, or fails with no earlier release to roll back to | The new release never became healthy (often a setting the application refuses at boot), or failed its smoke check | The command the failure prints, on the server: `sudo docker compose -p <project> logs --tail=80 <service>` |
| A nestjs-api never becomes healthy: its log says `SERVICE_NAME`, `DB_USER` … is required | A component created before Katap v2.0.2, whose settings lack the six the template now generates | `katap env <project> <component>`: add `SERVICE_NAME=<project>`, `DB_USER=app`, `DB_PASSWORD=` the `APP_DB_PASSWORD` in `/srv/secrets/<project>/<component>.db.env`, `DB_HOST=<component>-db`, `DB_PORT=5432`, `DB_NAME=app` |
| `prisma:seed` fails: SEED_USER_EMAIL and SEED_USER_PASSWORD must be set | A nestjs-api component created before Katap v2.0.4, whose settings have only the admin's | `katap env <project> <component>`: add `SEED_USER_EMAIL=` an address you own, and `SEED_USER_PASSWORD=` the output of `openssl rand -hex 24` |
| Deploy fails: … and so did putting the release before it back | The previous release did not come back healthy either | The component may be down: the logs the failure names, then `katap rollback <project> <component>` |

## Serving

| Symptom | Likely cause | Check |
|---|---|---|
| `502` from the edge | The upstream container is down or unhealthy | `docker ps --filter label=com.docker.compose.project=<project>`: a missing service is not running |
| No certificate (acme) | DNS not pointing at the server yet, or 80/443 blocked upstream | `docker compose -p katap-edge logs caddy` |
| `525` / `526` from Cloudflare | Origin certificate missing or wrong, or Authenticated Origin Pulls off | `ls -l /srv/edge/certs`, the Cloudflare dashboard; [Cloudflare mode](reference.md#cloudflare-mode) |
| Every client shares one IP | The application does not trust the edge's address, or Cloudflare proxies without Cloudflare mode | nestjs-api: `TRUST_PROXY` = `CADDY_IP`; behind Cloudflare: `katap edge cloudflare` |
| API logs `ECONNREFUSED` to its database | The database is still starting | `docker compose -p <project> logs <component>-db` |
| Disk filling up | Images no release needs, or releases that kept dumps still name | `katap images prune` (also nightly; logs are already capped). Each kept dump keeps the release it records: lower `KATAP_BACKUP_KEEP` to keep fewer ([What a backup covers](operations.md#what-a-backup-covers)) |
