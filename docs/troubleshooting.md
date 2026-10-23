# Troubleshooting

## Installing and connecting

| Symptom | Likely cause | Check |
|---|---|---|
| install: no published release | GitHub has no Release for Katap | Pass `--version vX.Y.Z` |
| install: has local changes | Files under `/srv/katap` were edited or added | `git -C /srv/katap status`; see [Updating Katap](updating.md#what-the-installer-refuses) |
| apply: no /srv/katap.json | The projects file is missing | Write it; see [The projects file](projects-file.md) |
| apply: … is claimed by both | One domain is listed for two components | Each domain belongs to one component, across every project |
| apply: a value contains whitespace or a control character | A pasted value carries a space, tab or line break | Edit the value; lists such as `domains` are JSON arrays |
| connect: could not read the server's release over SSH | The server is not in your `known_hosts`, SSH needs a password, or sudo asks for one | `ssh root@<server> true`; use root, or a user with passwordless sudo |
| connect: the server's ed25519 host key is not in your known_hosts | You have connected with another key type only, or never | [Verify the host key](server-access.md#3-verify-the-servers-host-key) against your provider's console, then run the `ssh -o HostKeyAlgorithms=ssh-ed25519 …` command it suggests |
| connect: … but GitHub's vX is … | The server runs a commit that is not that release | Run the installer again on the server |
| connect: … must allow deployments from exactly: main | The environment exists with no branch limit, or a wider one, so another branch could read its key | Set its deployment branches to exactly `main` (and `staging` for staging) in the repository's Settings → Environments, then run again |
| connect: cannot read … on GitHub | The repository in `/srv/katap.json` is misspelled, does not exist, or your `gh` login cannot see it | `repo` in `/srv/katap.json` (then `katap apply`); `gh repo view <owner>/<name>` |
| connect: your gh login does not administer … | `gh` is signed in as someone without admin rights on that repository | `gh auth status`; switch to an account that administers it: [When your own account isn't the repository's admin](connecting-apps.md#when-your-own-account-isnt-the-repositorys-admin) |
| connect: check that your gh login administers … | `gh` could read the repository but not its environments | Sign in to `gh` as an administrator of the repository |
| apply: … still serves | A domain moves to another component before its old site block is gone | See "Moving a domain" in [The projects file](projects-file.md#what-stays-yours) |
| apply: run apply as the owner of /srv/projects | apply was run as root | `sudo -u deploy /srv/katap/bin/katap apply` |

## Deploying

| Symptom | Likely cause | Check |
|---|---|---|
| Deploy refused: required values are empty | A `# katap:required` value is blank | `/srv/secrets/<project>/<component>.env` (`katap apply` lists them) |
| Deploy refused: … differs from /srv/katap.json | The `.conf` was edited, or `katap.json` changed without `apply` | `sudo -u deploy /srv/katap/bin/katap apply` |
| Deploy refused: could not verify that … was built by … | No matching attestation, a token problem, or no registry access to a private image. The `gh said:` part tells which | [When verification fails](connecting-apps.md#when-verification-fails); a registry message (`unauthorized`, `denied`) means [Private images](connecting-apps.md#private-images) |
| Deploy refused: set `KATAP_GH_TOKEN` | A component with `"provenance": "attested"`, and no token on the server | [Install the token](connecting-apps.md#install-the-token) |
| Deploy refused: this key deploys … only | The app's key is bound to another project or component | The repository's `KATAP_PROJECT`/`KATAP_COMPONENT`; run `connect.sh` again |
| Deploy refused: this key names no project and component | The key was authorised before keys were bound to a component | Delete the repository's `KATAP_SSH_KEY` secret and run `connect.sh` again |
| Deploy refused: already running, or dispatched less than 60s ago | Another deploy by that key or of that component is in progress, or one just finished | Wait, then re-run; its log is in `/srv/state/.dispatch/<project>/` |
| Deploy refused: … gh said: HTTP 401 (or another gh error) | The server's `KATAP_GH_TOKEN` expired, was revoked, or lacks access | [Rotate or replace the token](connecting-apps.md#rotate-or-replace-the-token); no restart needed |
| Deploy refused: could not pull … | The server can't read the image: a private package without a registry login, or an expired login | [Private images](connecting-apps.md#private-images) |
| Deploy refused: GitHub did not answer | GitHub's API was unreachable within 60s (`KATAP_GH_TIMEOUT`) | Retry; check the server's outbound network |
| Deploy refused: built from different commits | The runtime and migrate images come from different publish runs | Deploy one tag that names both |
| Deploy refused: has local modifications, or is not the release install.sh installed | `/srv/katap` was edited, or moved off the installed release | Run the installer again |
| Action fails: is not on ghcr.io / known-hosts is empty | The image is on another registry, or the `KATAP_KNOWN_HOSTS` secret is missing | Set the action's `registry` input; run `connect.sh` again |
| Deploy fails and rolls back | The new release never became healthy, or failed its smoke check | `docker compose -p <project> logs --tail=200 <service>` |

## Serving

| Symptom | Likely cause | Check |
|---|---|---|
| `502` from the edge | The upstream container is down or unhealthy | `docker ps --filter label=com.docker.compose.project=<project>`: a missing service is not running |
| No certificate (acme) | DNS not pointing at the server yet, or 80/443 blocked upstream | `docker compose -p katap-edge logs caddy` |
| `525` / `526` from Cloudflare | Origin certificate missing or wrong, or Authenticated Origin Pulls off | `ls -l /srv/edge/certs`, the Cloudflare dashboard |
| Every client shares one IP | The application does not trust the edge's address | nestjs-api: `TRUST_PROXY` = `CADDY_IP`; laravel-api: `TRUSTED_PROXIES=0.0.0.0/0` |
| API logs `ECONNREFUSED` to its database | The database is still starting | `docker compose -p <project> logs <component>-db` |
| Disk filling up | Old images | `docker image prune` (logs are already capped) |
