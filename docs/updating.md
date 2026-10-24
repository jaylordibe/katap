# Updating Katap

**Upgrade the server first, then the applications.** On the server, run the
installer again:

```bash
curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash
```

It moves `/srv/katap` to the latest release of the same major version, records
it in `/etc/katap/release`, and runs that release's `host/provision.sh`. Pin a
release with `--version vX.Y.Z`; moving to another major version always needs it. Going back to an earlier release works the same way: move
your applications' pins back first, since an older server may not know a newer
action's request. Read a release's notes before moving to it, above all a new
major version, which can change how deploys work.

Your projects, secrets, backups and data live under `/srv`, outside the tool, so a
release replaces only Katap itself:
- a change to a template affects only components created after it;
- a change to `edge/` takes effect at `katap edge up`.

Then move each application's pinned deploy step to the server's new release: the
commit is `commit=` in `/etc/katap/release` on the server, and the tag is `tag=`.
A server accepts requests from actions of its own release and of earlier
releases of the same major version, and refuses anything it does not recognise.

## From v1 to v2

v2 changes how applications deploy. **A v1 deploy key keeps working on a v2
server until you replace it**, and v2 checks no attestations, so do every step:

1. **Server:** `curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash -s -- --version v2.0.0`. It installs the `katap` command and no longer uses a GitHub token.
2. **Old credentials on the server:**
   - delete `KATAP_GH_TOKEN` from `/etc/katap/katap.env`, and revoke that token on GitHub;
   - if you once ran `sudo -u deploy docker login ghcr.io`, run `sudo -u deploy docker logout ghcr.io` and revoke that token too. Deploys pull with each job's own token.
3. **`/srv/katap.json`:** delete any `"provenance"`, then `katap apply`. It also removes v1's `source_repo` and `provenance` from each component's `.conf`.
4. **laravel-api components:** trust only the edge. Rebuild the application from laravel-api at or after commit `0077bff`, then set `TRUSTED_PROXIES` to the edge's address (`CADDY_IP` in `/srv/edge/edge.env`) with `katap env <project> <component>` before deploying that build. Those builds refuse v1's `0.0.0.0/0`; an older build needs `0.0.0.0/0`, because its Laravel reads the same variable in another format.
5. **Each component:** `katap deploy-key <project> <component> --replace`, and put the secrets it prints in the repository.
6. **Each repository:**
   - replace `.github/workflows/deploy.yml` with the deploy step `katap deploy-key` printed, at the end of the workflow that builds the image (see [Deploying](deploying.md));
   - delete the `PUBLISH_ENABLED` variable and the `KATAP_*` secrets of the old GitHub environments.
7. **Check no v1 key is left.** List every deploy key with its fingerprint:
   ```bash
   sudo ssh-keygen -lf /home/deploy/.ssh/authorized_keys
   sudo grep -n ssh-dispatch /home/deploy/.ssh/authorized_keys | grep -E 'ssh-dispatch [a-z]+ [a-z0-9-]+ [a-z0-9]*,'
   ```
   There should be exactly one key per component and environment, each one `katap deploy-key` made in step 5. The second command prints any key bound to several components (`ssh-dispatch production shop api,web`), which only v1 made. Delete every line that is not one of step 5's keys.

A v1 project that was never deployed can be removed and created again instead:
`katap remove <project> --confirm <project>`.

### Going back to v1

Only if v2 does not work for you:

1. Move each application's workflow back to its v1 `deploy.yml` and `publish-image.yml`, or set `"provenance": "none"` for those components in `/srv/katap.json`: v1 refuses images without an attestation.
2. Put a `KATAP_GH_TOKEN` back in `/etc/katap/katap.env`, as v1's README says.
3. `curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash -s -- --version v1.1.1`, then `sudo -u deploy /srv/katap/bin/katap apply`.

v1's `katap apply` printed a `connect.sh` command from `main`; that script is no
longer on `main`. On a v1 server use the one from your release instead:
`https://raw.githubusercontent.com/jaylordibe/katap/v1.1.1/connect.sh`.

## What the installer refuses

Each refusal changes nothing:

| Refusal | Why | What to do |
|---|---|---|
| `has local changes` | Files under `/srv/katap` were edited or added. An upgrade would lose them, and the installer runs as root | `git -C /srv/katap status`; move your changes out of the tool (projects belong in `/srv/katap.json` and `/srv/projects`), then `git -C /srv/katap checkout -- .` and remove the added files |
| `no published release` | GitHub has no Release for Katap yet | Use `--version` with a release tag at or after v1.1.0 |
| `GitHub refused the request (rate limit)` | Too many anonymous GitHub API calls from this address | Wait, or pass `--version vX.Y.Z` |
| `older than this installer supports` | v1.0.0 predates the installer | Install it by hand, as its own README says |

## Deploys check the release too

A deploy refuses to run when `/srv/katap` has local modifications, or is not at the
commit `/etc/katap/release` names. Running the installer again puts it right.
