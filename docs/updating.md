# Updating Katap

**Upgrade the server first, then the applications.** On the server, run the
installer again:

```bash
curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash
```

It moves `/srv/katap` to the latest release, records it in `/etc/katap/release`,
and runs that release's `host/provision.sh`. Pin a release with
`--version vX.Y.Z`. Going back to an earlier release works the same way: move
your applications' pins back first, since an older server may not know a newer
action's request. Read a release's notes before moving to it, above all a new
major version, which can change how deploys work.

Your projects, secrets, backups and data live under `/srv`, outside the tool, so a
release replaces only Katap itself. Read the release notes first:
- a change to a template affects only components created after it;
- a change to `edge/` takes effect at `sudo -u deploy /srv/katap/bin/katap edge up`.

Then update each application's pinned action. Running
[`connect.sh`](connecting-apps.md) again prints the command that rewrites
`deploy.yml` with the server's new release; commit it in each repository. The action and the server speak through
one request (`deploy <project> <component> <digest> [migrate=<digest>]`). A server
accepts requests from actions of its own release and of earlier releases of the
same major version, and refuses anything it does not recognise.

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
commit `/etc/katap/release` names. `katap release-info`, which `connect.sh` reads,
refuses the same way. Running the installer again puts both right.
