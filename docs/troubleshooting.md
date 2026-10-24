# Troubleshooting

## Installing and setting up

| Symptom | Likely cause | Check |
|---|---|---|
| install: no published release | GitHub has no Release for Katap | Pass `--version vX.Y.Z` |
| install: … a new major version that changes how deploys work | The latest release is a new major version | Read [Updating Katap](updating.md), then pass `--version` with that release |
| install: has local changes | Files under `/srv/katap` were edited or added | `git -C /srv/katap status`; see [Updating Katap](updating.md#what-the-installer-refuses) |
| apply: no /srv/katap.json | The projects file is missing | Write it; see [The projects file](projects-file.md) |
| apply: no terminal to confirm on | apply has something to create or change, and nothing to ask on | Run it in a terminal, or `katap apply --yes` |
| apply: … provenance is no longer a setting | A v1 `katap.json` | Delete `"provenance"` from that component |
| apply: … is claimed by both | One domain is listed for two components | Each domain belongs to one component, across every project |
| apply: a value contains whitespace or a control character | A pasted value carries a space, tab or line break | Edit the value; lists such as `domains` are JSON arrays |
| apply: … still serves | A domain moves to another component before its old site block is gone | See "Moving a domain" in [The projects file](projects-file.md#what-stays-yours) |
| deploy-key: already has a … deploy key | The component has a key | `katap deploy-key <project> <component> --replace`, then update the repository's secret |
| deploy-key: set host | `host` is empty in `/srv/katap.json` | Set the server's public IPv4 address there |
| remove: … was deployed / has data volumes / has secrets of a component that is not being removed | `katap remove` only removes what never ran, and never another component's files | Removing a deployed component is deliberate work, by hand |
| apply, deploy-key, remove: run … as the owner of /srv/projects | Run with `sudo` straight from `/srv/katap/bin/katap` | Use the `katap` command, which runs it as the deploy user |

## Deploying

| Symptom | Likely cause | Check |
|---|---|---|
| Deploy refused: required values are empty | A `# katap:required` value is blank | `katap env <project> <component>` |
| Deploy refused: … differs from /srv/katap.json | A `.conf` was edited, or `katap.json` changed without `apply` | `katap apply` |
| Deploy refused: … is not this component's repository | The workflow pushed to another image repository than the component's | `repo` (or `image`) in `/srv/katap.json`, and where the workflow pushes |
| Deploy refused: could not pull … | The image isn't on the server, and the pull failed: a wrong digest, or a private image deployed without the workflow's token | The deploy step's `image`; the deploy job's `permissions: packages: read`. A rollback or restore by hand of a private image no longer on the server: `sudo -u deploy docker login ghcr.io` with a `read:packages` token, then `docker logout ghcr.io` |
| laravel-api restarts: TRUSTED_PROXIES must not include a /0 network | A component created before Katap v2, deploying a laravel-api build from commit `0077bff` or later | `katap env <project> <component>`: set `TRUSTED_PROXIES` to `CADDY_IP` from `/srv/edge/edge.env` |
| laravel-api builds `http://` links behind the edge | A laravel-api build from before commit `0077bff`, with `TRUSTED_PROXIES` set to the edge's address | Rebuild from current laravel-api |
| Deploy refused: could not log in to ghcr.io | The job's token could not read the package | The package's access: a package published by the repository's own workflow can be read by its token |
| Deploy refused: standard input must be one line | A modified action, or one from a newer release than the server | Pin the step to your server's release, as `katap deploy-key` prints it |
| Action warns: registry-token is not this job's GitHub token | `registry-token` set to a personal token | Leave `registry-token` unset; give the job `permissions: packages: read` |
| Deploy refused: this key deploys … only | The step's `project` or `component` is not the key's | The step's `project` and `component`, as `katap deploy-key` printed them |
| Deploy refused: this key names no project and component | A v1 key | `katap deploy-key <project> <component> --replace` |
| Deploy refused: already running, or dispatched less than 60s ago | Another deploy of that component is in progress, or one just finished | Wait, then re-run; its log is in `/srv/state/.dispatch/<project>/` |
| Deploy refused: has local modifications, or is not the release install.sh installed | `/srv/katap` was edited, or moved off the installed release | Run the installer again |
| Action fails: is not on ghcr.io / known-hosts is empty | The image is on another registry, or the `KATAP_KNOWN_HOSTS` secret is missing | Set the action's `registry` input; add the secret `katap deploy-key` printed |
| Action fails: Permission denied (publickey) | The `KATAP_SSH_KEY` secret is not the key the server has, or was pasted without its first or last line | Replace it: `katap deploy-key <project> <component> --replace` |
| Deploy fails and rolls back | The new release never became healthy, or failed its smoke check | `docker compose -p <project> logs --tail=200 <service>` |

## Serving

| Symptom | Likely cause | Check |
|---|---|---|
| `502` from the edge | The upstream container is down or unhealthy | `docker ps --filter label=com.docker.compose.project=<project>`: a missing service is not running |
| No certificate (acme) | DNS not pointing at the server yet, or 80/443 blocked upstream | `docker compose -p katap-edge logs caddy` |
| `525` / `526` from Cloudflare | Origin certificate missing or wrong, or Authenticated Origin Pulls off | `ls -l /srv/edge/certs`, the Cloudflare dashboard; [Cloudflare mode](reference.md#cloudflare-mode) |
| Every client shares one IP | The application does not trust the edge's address, or Cloudflare proxies without Cloudflare mode | nestjs-api: `TRUST_PROXY` = `CADDY_IP`; behind Cloudflare: `katap edge cloudflare` |
| API logs `ECONNREFUSED` to its database | The database is still starting | `docker compose -p <project> logs <component>-db` |
| Disk filling up | Images no release needs | `katap images prune` (also nightly; logs are already capped) |
