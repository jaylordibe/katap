# The projects file and `katap apply`

`/srv/katap.json` says which projects and components the server runs. `katap apply`
creates what is missing and keeps the rest in line with it. Edit the file as root,
then apply:

```bash
sudo nano /srv/katap.json
katap apply
```

## The file

```json
{
  "host": "203.0.113.10",
  "projects": {
    "shop": {
      "api": { "type": "laravel-api", "repo": "you/shop-api", "domains": ["api.example.com"] },
      "web": { "type": "spa",         "repo": "you/shop-web", "domains": ["example.com", "www.example.com"] }
    },
    "shop-staging": {
      "api": { "type": "laravel-api", "repo": "you/shop-api", "domains": ["api.staging.example.com"], "environment": "staging" }
    }
  }
}
```

| Key | Required | Meaning |
|---|---|---|
| `host` | for DNS and deploy keys | The server's public IPv4 address. Printed in the DNS records, and in `katap deploy-key`'s secrets: the address applications deploy to |
| `projects.<project>` | | Lowercase letters, digits and hyphens, starting with a letter (30 at most). Each project gets its own network, database and Redis per component |
| `.<component>` | | Lowercase letters and digits, no hyphen (20 at most) |
| `type` | yes | `laravel-api`, `nestjs-api`, `spa` or `node-ssr` (a file in `templates/`) |
| `repo` | yes | The GitHub repository that builds the image, `owner/name`. It names the image (below), and one repository deploys one component per environment. Which builds may deploy is decided by who holds the deploy key: see [Security model](security.md#known-limits) |
| `domains` | no | Where it is served. None: internal only |
| `environment` | no | `production` (default) or `staging`. Put a staging copy in its own project, as above |
| `image` | no | The image repository. Default `ghcr.io/<repo>`, lowercased |

Never put a secret in this file; secrets live in `/srv/secrets`. The file is owned
by root and only read by the deploy user: nothing a deploy runs can change what
the server deploys.

## What apply does

Before writing anything, apply checks the whole file:
- every name against the rules above;
- `type` against `templates/`;
- `repo` and `image` formats;
- that each domain belongs to one component across every project, including components made by hand, and is not still served by another component's `.conf` or `site.caddy`;
- that no existing component changes type, and no repository is listed twice for one environment.

The first problem stops it, with nothing written. Then it lists what it will
create or change, and asks before writing anything. With no terminal to ask on,
it needs `katap apply --yes`. With nothing to create or change, it asks nothing.
Then, for each project:

- **A new component** is created exactly as `katap add` would: its compose file, its `.conf` and a block in `site.caddy`. Then its secrets are generated as `katap secrets` would. A laravel-api's `APP_FRONTEND_URL` and `CORS_ALLOWED_ORIGINS`, and a nestjs-api's `WEB_BASE_URL` and `CORS_ORIGIN`, come from the project's one spa or node-ssr component with domains. With none or several, they stay for you to fill in.
- **An existing component** has only the keys this file owns rewritten in its `.conf`: `image`, `image_migrate`, `environment` and `domains`. Its type never changes.

Then it reloads the edge (validated first; nothing happens while the edge is
down), and prints:
- the A records to add;
- the values still empty (a deploy is refused while one is);
- anything to check by hand;
- components the file does not mention;
- what to do next: `katap env` and `katap deploy-key` for each component (see [Deploying](deploying.md)).

Running it again changes nothing.

## What stays yours

After the first apply, these are never rewritten:

| File | Edit it to |
|---|---|
| `/srv/projects/<project>/<component>.yml` | Tune memory (`mem_limit`), add a worker. The compose file is copied once from its template |
| `/srv/projects/<project>/<component>.conf`, keys other than `type` and the table's `image`, `environment` and `domains` (and `image_migrate`, which follows `image`) | Change `rollout=`, `smoke_path=` and so on, to match your compose file |
| `/srv/projects/<project>/site.caddy` | Add a redirect, protect staging. A new component appends its block; a changed `domains` list is reported, and you edit the file, then run `katap edge reload` |
| `/srv/secrets/<project>/<component>.env` | Fill in the values only you know. Generated once, never regenerated. Values derived from a domain (`APP_URL`, the frontend URL) are reported when the file no longer matches, never rewritten |

**Moving a domain takes two applies.** Remove it from the component that has it
and apply; edit that project's `site.caddy` to drop its block; then add it to the
new component and apply again. Two site blocks for one name would stop the edge,
so apply refuses a domain another component still serves.

**Nothing is ever removed.** A component you delete from the file is listed as
"not in katap.json" and keeps running, but **no longer deploys**: its deploy key
is refused (a rollback still works). Stopping it and removing its data is
deliberate work for you, not for apply: see
[Taking a deployed component off the server](#taking-a-deployed-component-off-the-server).

**A deploy follows the file.** `katap check`, which every deploy runs, refuses a
component whose `.conf` disagrees with `katap.json` until `katap apply` has run,
and refuses a project's deploys while the file has a problem in that project (or
does not parse at all); a problem in another project's part holds only that
project. A rollback never reads it: the way back does not depend on a file being
edited.

Apply runs as the deploy user, which the `katap` command does for you; run as
anyone who does not own `/srv/projects`, it refuses, so a project is never left
owned by root.

## Removing a mistake

A component created by mistake (a typo in a project name, say) and never
deployed: remove it from `/srv/katap.json` first, then

```bash
katap remove <project> <component> --confirm <project>
```

Without a component, every component of the project goes, and then the project.
It removes the compose file, the `.conf`, the site block, the generated settings
and the deploy key, and reloads the edge. It refuses anything that has served a
release, has containers or holds data: removing those is deliberate work, by hand.

## Taking a deployed component off the server

For a component that ran, in this order:

1. Delete it from `/srv/katap.json`, then `katap apply`. From now on it no longer deploys.
2. `katap deploy-key <project> <component> --revoke`: its key stops working. Delete its secrets and variables from the repository.
3. If it has a database: `katap backup <project>`, and copy the newest dump in `/srv/backups/<project>/` somewhere safe.
4. Move its `<component>.yml` and `<component>.conf` out of `/srv/projects/<project>/` (keep them until step 7): Katap stops running its scheduled jobs and nightly dumps.
5. Stop and remove its containers: `sudo docker ps -a --filter label=com.docker.compose.project=<project>` lists them; its services are named `<component>` and `<component>-…`.
6. Remove its block from `/srv/projects/<project>/site.caddy`, then `katap edge reload`.
7. Once you are sure, delete what is left, by exact name (another component's name can start with this one's):
   - in `/srv/secrets/<project>/`: `<component>.env`, `<component>.db.env`, `<component>.redis.env` and the directory `<component>-db-tls/`;
   - its lines in `/srv/state/<project>/images.env`, so `katap images prune` can remove its images. Under the project's lock, as Katap itself writes it, so no deploy lands in between (for component `api`): `sudo -u deploy flock /srv/state/<project>/.lock sed -i -E '/^IMAGE_API(_MIGRATE)?=/d' /srv/state/<project>/images.env`;
   - its volumes, `<project>_<component>-db` and `<project>_<component>-redis` (`sudo docker volume ls --filter label=com.docker.compose.project=<project>` lists them).

## Application settings

`katap apply` writes each component's settings to `/srv/secrets/<project>/<component>.env`
(mode 0600, owned by `deploy`), from its template's `templates/<type>.env.spec`:

- **Generated** values are made once on the server: keys, database and Redis passwords, Passport keys and so on. Never change them on a running application: a new `APP_KEY` or database password breaks existing data and logins.
- **Derived** values come from `katap.json`: `APP_URL` from the first domain, and the frontend URL and CORS origins from the project's single `spa` or `node-ssr` component with domains.
- **Yours to supply** are left empty under a `# katap:required` marker, and a deploy is refused while any of them is empty.

| Template | Required values you supply | Where accepted values are documented |
|---|---|---|
| `laravel-api` | `MAIL_MAILER`, `MAIL_FROM_ADDRESS`; `APP_FRONTEND_URL` and `CORS_ALLOWED_ORIGINS` when the project has no single frontend | [laravel-api DEPLOYMENT.md](https://github.com/jaylordibe/laravel-api/blob/main/DEPLOYMENT.md), "Environment contract" and "Object storage contract" |
| `nestjs-api` | `EMAIL_PROVIDER`, `EMAIL_FROM`, `SMS_PROVIDER`, `STORAGE_PROVIDER`, `TURNSTILE_WEB_SECRET`, `TURNSTILE_MOBILE_SECRET`, `SEED_ADMIN_EMAIL`, `SEED_USER_EMAIL`; `WEB_BASE_URL` and `CORS_ORIGIN` when the project has no single frontend | [nestjs-api deployment contract](https://github.com/jaylordibe/nestjs-api/blob/main/docs/deployment/README.md), "Environment contract" |
| `node-ssr` | None. Add the runtime variables your server reads | Your application |
| `spa` | None. A static site reads no runtime settings; see [build-time settings](reference.md#build-time-and-runtime-settings) | Your application |

**Edit the file** (*server SSH session*): `katap env <project> <component>`. It
opens the file in an editor, then lists the required values still empty, by name
only. Add the values the starter's documentation asks for, such as mail
credentials and the settings for a storage provider.

**Katap only checks that marked values aren't empty.** It doesn't check that a
value is valid, that a mail provider accepts the credentials, or that a bucket
exists. It doesn't check settings without a `# katap:required` marker either. The
starter applications validate part of their configuration when they start. A
value that stops them starting fails the deploy's healthcheck, and the deploy rolls
back. Others, such as wrong mail credentials, only show up when they're used.

**Object storage:** creating a bucket configures nothing by itself. The
application needs its storage settings (see the starter's object storage
contract) and credentials that can reach the bucket. Katap's off-server backups are
configured separately again: see [What a backup covers](operations.md#what-a-backup-covers).

**When a change takes effect:** a running container keeps the settings it started
with. One-shot services, such as the scheduler and `katap run` commands, read the
file each time they start. The long-running services pick up a change only when
they're recreated. A deploy runs `docker compose up -d --wait` for each service in
the component's `rollout=`, and Compose recreates a service only when its
configuration changed: a new image, or new settings. Services outside `rollout=`,
such as the database, are left alone unless their own configuration changed.

### Applying a settings change without a new build

Deploy the release that is serving now again, on the server. It is already
there, so nothing is pulled (*server SSH session*, for `shop`/`api`):

```bash
katap deploy shop api "$(sed -n 's/^IMAGE_API=//p' /srv/state/shop/images.env)"
```

A nestjs-api also passes its migrate image:
`migrate="$(sed -n 's/^IMAGE_API_MIGRATE=//p' /srv/state/shop/images.env)"`.

This is a normal deploy: a pre-deploy dump, the template's pre-deploy steps
(migrations, which apply nothing when none are pending), the rollout with
healthchecks and the smoke check, and an automatic rollback if the release never
becomes healthy.

## Without the file

`katap add <project> <type> <component> [domain...]` and `katap secrets <project>
<component>` still create one component by hand. You then set `image=` in its
`.conf` yourself. Apply leaves such components alone; it only
refuses to give one of their domains to another component.

**Once `katap apply` has run on the server, or `/srv/katap.json` lists any
project, the file is the list of what deploys:** a component it does not list is
refused at deploy, even after its last project is removed. Add a component made
by hand to the file to keep deploying it; `katap apply` then adopts its `.conf`.
