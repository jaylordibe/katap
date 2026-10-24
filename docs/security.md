# Security model

| Concern | How Katap handles it |
|---|---|
| **Exposure** | Only 22, 80 and 443 are open, and only Caddy publishes a port. Each project's database and Redis sit on that project's private network; another project cannot even resolve their names |
| **Secrets** | Generated once on the server, mode 0600, never in git and never regenerated. The database superuser password is readable only by the database container; the app connects as a non-superuser role that owns its database. Secrets never go in `/srv/katap.json` |
| **Deploy keys** | One per component and environment, made by `katap deploy-key`: `restrict,command="katap ssh-dispatch <environment> <project> <component>"`. A key can deploy its own component, or roll it back to a release this server has served, with validated arguments, one at a time, and nothing else. Each dispatch is logged with the key's binding and the client address |
| **What may deploy** | Only images from the component's own image repository, by digest. `/srv/katap.json` is root's and only read by the deploy user; a deploy is refused while a component's `.conf` disagrees with it |
| **Registry credentials** | Katap stores none. A deploy pulls a private image with the GitHub Actions job's own token, sent on the SSH session's input (never in the request, which is logged), written to a 0600 file the worker reads once and removes, and used once, for `ghcr.io` only, in a Docker configuration deleted after the pull. The token expires when the job ends. Give the deploy job only `permissions: packages: read`: the server receives whatever that token may do |
| **Supply chain** | Images are built and scanned in the application's own CI and deployed by digest. Caddy, PostgreSQL, Redis and the smoke-check image are pinned by digest in Katap's templates |
| **The tool** | `/srv/katap` is root's, at the commit of a release. A deploy refuses a tool with local modifications, or one not at the commit `/etc/katap/release` names |
| **Destructive operations** | Katap automates none. Nothing drops a volume, regenerates a key or runs a fresh migration. `restore` is human-only, needs `--confirm`, and dumps first. `apply` never removes anything; `remove` removes only components that never ran. The application's own forward migrations do run on every deploy, after a pre-deploy dump, and are never reversed automatically |

## The installer

It is fetched from `main` on GitHub, which keeps the one-line command the same
across every release, and does as little as it can on `main`'s authority. It
runs as root, finds the latest GitHub Release, resolves its tag to a commit,
checks the tool out at exactly that commit with git hooks off, then hands over to
that release's own `host/provision.sh`. It refuses a tool directory with local
changes.

What this rests on is the integrity of the `jaylordibe/katap` repository: its
`main` branch, its release tags and its Releases. A fork changes the name in
`install.sh` and in its deploy step, and protects its own repository the same way:
- a ruleset that requires pull requests on `main`;
- a ruleset that blocks updating and deleting `v*` tags;
- immutable releases.

## Known limits

These are accepted as residual risk:

- **Anyone who can push to an application repository can deploy it.** Its deploy key is a repository secret, which every GitHub plan offers, and any workflow on any branch can read it. On GitHub Free private repositories, anyone who can push can already change `main`. The key still deploys only its own component. Binding deploys to `main` with GitHub's OIDC token is not built.
- **No build provenance is checked.** The server deploys any image of the component's own repository that the key holder sends, including an older build, migrations included.
- **Components of one project share its lock.** A deploy key can delay the other components of its own project, by at most one deploy at a time, a minute apart. It can never delay another project's. Keep staging in its own project.
- **The one-line installer runs `main`'s script.** Its integrity is GitHub account security and the repository's rulesets. Tags are not signed, and the installer does not detect a tag moved after a server installed it: protect `v*` tags and turn on immutable releases.
- **Cloudflare's Authenticated Origin Pulls are global.** The edge admits any Cloudflare zone's origin-pull certificate, so someone with their own Cloudflare zone could point it at your server's address. They reach only what any visitor reaches.
- **Leaving Cloudflare mode** (`katap edge acme`): the edge removes Cloudflare's client-address headers at once, and each nestjs-api stops trusting them at its next deploy.
- **IPv4 only.** The edge publishes no IPv6 port; publish no AAAA record.
- **The `deploy` user is root-equivalent** through the `docker` group. Protect its keys; `katap deploy-key` prints a private key once, so clear your terminal after saving it in GitHub.
- **Public components share the edge network.** One project's public service could call another's directly. Only the edge's own address may set a client address. Databases stay unreachable.
- **laravel-api's database link uses `sslmode=require`:** encrypted, but the certificate is not verified. The traffic never leaves the server.
- **Have a person review the deploy path** before trusting it with real data. Automated tests do not replace that review.
