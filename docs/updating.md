# Updating Katap

**Upgrade the server first, then the applications.** On the server, run the
installer again:

```bash
curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash
```

It moves `/srv/katap` to the latest release, records it in `/etc/katap/release`,
and runs that release's `host/provision.sh`. When the latest release is a new
major version, it refuses and changes nothing: moving to another major version
always needs `--version vX.Y.Z`, after reading that release's notes. The same flag
pins any release, earlier ones included.

Your projects, secrets, backups and data live under `/srv`, outside the tool, so a
release replaces only Katap itself:
- a change to a template affects only components created after it;
- a change to `edge/` takes effect at `katap edge up`.

**The applications' pins can move on their own.** Within a major version, the
request the deploy step sends never changes form, so any v2 deploy step works
with any v2 server, in either order. Dependabot's `github-actions` updates move
each repository's `jaylordibe/katap@<commit>` pin to new releases. The server
checks a request's form, not the step's release, and refuses anything else.

## From v1 to v2

v2 changes how applications deploy. **A v1 deploy key keeps working on a v2
server until you replace it**, and v2 checks no attestations, so do every step:

1. **Server:** `curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash -s -- --version v2.0.1`. It installs the `katap` command, no longer uses a GitHub token, and restarts the edge with v2's configuration.
2. **Old credentials and tools on the server:**
   - delete `KATAP_GH_TOKEN` from `/etc/katap/katap.env`, and revoke that token on GitHub;
   - if you once ran `sudo -u deploy docker login ghcr.io`, run `sudo -u deploy docker logout ghcr.io` and revoke that token too. Deploys pull with each job's own token;
   - v1 installed the GitHub CLI to check attestations. Unless you use it yourself: `sudo apt-get remove -y gh && sudo rm /etc/apt/sources.list.d/github-cli.list /etc/apt/keyrings/githubcli-archive-keyring.gpg`.
3. **`/srv/katap.json`:** delete any `"provenance"`, and list every component this server deploys, including any made with `katap add` (v1.0.0 servers): once the file lists a project, a component it does not list no longer deploys. Then `katap apply`. It also removes v1's `source_repo` and `provenance` from each component's `.conf`.
4. **Each component's compose file** (`/srv/projects/<project>/<component>.yml`, copied once from v1's template): add `cap_drop: [NET_RAW]` to every service, as v2's templates have. A deploy warns about each service still without it. See [Security model](security.md).
5. **laravel-api components:** trust only the edge. Rebuild the application from laravel-api at or after commit `0077bff`, then set `TRUSTED_PROXIES` to the edge's address (`CADDY_IP` in `/srv/edge/edge.env`) with `katap env <project> <component>` before deploying that build. Those builds refuse v1's `0.0.0.0/0`; an older build needs `0.0.0.0/0`, because its Laravel reads the same variable in another format.
6. **Each component:** `katap deploy-key <project> <component> --replace`, and add the secrets and variables it prints to the repository, as repository secrets and variables.
7. **Each repository:**
   - delete `.github/workflows/deploy.yml`, and the old GitHub environments with their `KATAP_*` secrets;
   - keep `publish-image.yml` and its `PUBLISH_ENABLED` variable, and add Katap's deploy jobs to it, as [The workflow](deploying.md#2-the-workflow) says;
   - give its `publish` job the pushed digest as an output, if it has none. In a repository made from v1's `examples/publish-image.yml` or from laravel-api: `outputs:` then `image: ${{ steps.name.outputs.image }}@${{ steps.build.outputs.digest }}`. In one made from nestjs-api: copy the `outputs:` lines of the starter's current `publish-image.yml`.
8. **Check no v1 key is left.** List every deploy key with its fingerprint:
   ```bash
   sudo ssh-keygen -lf /home/deploy/.ssh/authorized_keys
   sudo grep -n ssh-dispatch /home/deploy/.ssh/authorized_keys | grep -E 'ssh-dispatch [a-z]+ [a-z0-9-]+ [a-z0-9]*,'
   ```
   There should be exactly one key per component and environment, each one `katap deploy-key` made in step 6. The second command prints any key bound to several components (`ssh-dispatch production shop api,web`), which only v1 made. Delete every line that is not one of step 6's keys.

A v1 project that was never deployed can be removed and created again instead:
delete it from `/srv/katap.json`, run `katap remove <project> --confirm <project>`,
then add it back and run `katap apply`.

### Going back to v1

Only if v2 does not work for you:

1. Move each application's workflow back to its v1 `deploy.yml` and `publish-image.yml` (removing the Katap deploy jobs), or set `"provenance": "none"` for those components in `/srv/katap.json`: v1 refuses images without an attestation.
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
