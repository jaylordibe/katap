# Security model

| Concern | How Katap handles it |
|---|---|
| **Exposure** | Only 22, 80 and 443 are open, and only Caddy publishes a port. Each project's database and Redis sit on that project's private network; another project cannot even resolve their names |
| **Secrets** | Generated once on the server, mode 0600, never in git and never regenerated. The database superuser password is readable only by the database container; the app connects as a non-superuser role that owns its database. Secrets never go in `/srv/katap.json` |
| **Supply chain** | Images are scanned in CI and deployed by digest. **The server verifies each image's build provenance itself**, against its own project settings, before pulling anything. Caddy, PostgreSQL, Redis and the smoke-check image are pinned by digest |
| **Deploy keys** | One per application and environment: `restrict,command="katap ssh-dispatch <environment> <project> <component>"`. A key can deploy its own component, or roll it back to a release this server has served, with validated arguments, one at a time, and nothing else. Each dispatch is logged with the key's binding and the client address |
| **What may deploy** | `/srv/katap.json` is root's and only read by the deploy user. A deploy is refused while a component's `.conf` disagrees with it |
| **The tool** | `/srv/katap` is root's, at the commit of a release. A deploy refuses a tool with local modifications, or one not at the commit `/etc/katap/release` names |
| **Destructive operations** | None are automated. Nothing drops a volume, regenerates a key or runs a fresh migration. `restore` is human-only, needs `--confirm`, and dumps first. `apply` never removes anything |

## The installer and connect.sh

Both are fetched from `main` on GitHub. That is what keeps the one-line commands
the same across every release. Each does as little as it can on `main`'s
authority:

- **`install.sh`** runs as root. It finds the latest GitHub Release and resolves its tag to a commit. It checks the tool out at exactly that commit with git hooks off, then hands over to that release's own `host/provision.sh`. It refuses a tool directory with local changes.
- **`connect.sh`** runs on your computer with your `gh` login. It treats everything the server sends as data and checks each value. It refuses to continue unless:
  - the server's release is the commit GitHub has for that tag;
  - the server's host key is one your `known_hosts` already trusts.

  It asks before it changes anything. It creates each GitHub environment limited to its branches before any key exists, and refuses one not limited to exactly those branches. A deploy key exists on your computer only in a temporary directory, removed however the script ends, and reaches GitHub on standard input, never in a command line.

What this rests on is the integrity of the `jaylordibe/katap` repository: its
`main` branch, its release tags and its Releases. Both scripts name that
repository; a fork changes the name in `install.sh`, `connect.sh` and
`examples/deploy.yml`, and protects its own repository the same way:
- a ruleset that requires pull requests on `main`;
- a ruleset that blocks updating and deleting `v*` tags;
- immutable releases.

## Known limits

These are accepted as residual risk:

- **Approval lives in each application repository.** The server bounds *what* can deploy (that app's attested builds, `main` for production), not *who approved it*. Any attested build of `main` qualifies, including an older one: a key holder can move a component back to an earlier `main` build, migrations included.
- **Components of one project share its lock.** A deploy key can delay the other components of its own project, by at most one deploy at a time, a minute apart, however many components it is bound to. It can never delay another project's. Keep staging in its own project.
- **The server holds a GitHub token.** Keep it read-only and fine-grained.
- **The one-line commands run `main`'s installer and connect script.** Their integrity is GitHub account security and the repository's rulesets. Tags are not signed, and the installer does not detect a tag moved after a server installed it: protect `v*` tags and turn on immutable releases.
- **IPv4 only.** The edge publishes no IPv6 port; publish no AAAA record.
- **The `deploy` user is root-equivalent** through the `docker` group. Protect its keys.
- **Public components share the edge network.** One project's public service could call another's directly, and a laravel-api trusts any address there to set the client IP. Databases stay unreachable.
- **laravel-api's database link uses `sslmode=require`:** encrypted, but the certificate is not verified. The traffic never leaves the server.
- **Have a person review the deploy path** before trusting it with real data. Automated tests do not replace that review.
