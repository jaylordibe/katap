# The projects file and `katap apply`

`/srv/katap.json` says which projects and components the server runs. `katap apply`
creates what is missing and keeps the rest in line with it. Edit the file as root,
then apply as the deploy user:

```bash
sudo nano /srv/katap.json
sudo -u deploy /srv/katap/bin/katap apply
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
| `host` | for DNS and connect | The server's public IPv4 address. Printed in the DNS records; the address applications deploy to |
| `projects.<project>` | | Lowercase letters, digits and hyphens, starting with a letter (30 at most). Each project gets its own network, database and Redis per component |
| `.<component>` | | Lowercase letters and digits, no hyphen (20 at most) |
| `type` | yes | `laravel-api`, `nestjs-api`, `spa` or `node-ssr` (a file in `templates/`) |
| `repo` | yes | The GitHub repository that builds the image, `owner/name`. Only its own publish workflow's builds deploy. One repository deploys one component per environment |
| `domains` | no | Where it is served. None: internal only |
| `environment` | no | `production` (default) or `staging`. Put a staging copy in its own project, as above |
| `provenance` | no | `attested` (default): only images GitHub attests were built by `repo`'s `publish-image.yml`. `none`: for a private repository on a plan without attestations; anything pushed to the image repository can then deploy |
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

The first problem stops it, with nothing written. Then, for each project:

- **A new component** is created exactly as `katap add` would: its compose file, its `.conf` and a block in `site.caddy`. Then its secrets are generated as `katap secrets` would. A laravel-api's `APP_FRONTEND_URL` and `CORS_ALLOWED_ORIGINS`, and a nestjs-api's `WEB_BASE_URL` and `CORS_ORIGIN`, come from the project's one spa or node-ssr component with domains. With none or several, they stay for you to fill in.
- **An existing component** has only the keys this file owns rewritten in its `.conf`: `image`, `image_migrate`, `source_repo`, `environment`, `domains` and `provenance`. Its type never changes.

Then it reloads the edge (validated first; nothing happens while the edge is
down), and prints:
- the A records to add;
- the values still empty (a deploy is refused while one is);
- anything to check by hand;
- components the file does not mention;
- the laptop command that connects every application (see [Connecting applications](connecting-apps.md)).

Running it again changes nothing.

## What stays yours

After the first apply, these are never rewritten:

| File | Edit it to |
|---|---|
| `/srv/projects/<project>/<component>.yml` | Tune memory (`mem_limit`), add a worker. The compose file is copied once from its template |
| `/srv/projects/<project>/<component>.conf`, keys other than the six above | Change `rollout=`, `smoke_path=` and so on, to match your compose file |
| `/srv/projects/<project>/site.caddy` | Add a redirect, protect staging. A new component appends its block; a changed `domains` list is reported, and you edit the file, then run `katap edge reload` |
| `/srv/secrets/<project>/<component>.env` | Fill in the values only you know. Generated once, never regenerated. Values derived from a domain (`APP_URL`, the frontend URL) are reported when the file no longer matches, never rewritten |

**Moving a domain takes two applies.** Remove it from the component that has it
and apply; edit that project's `site.caddy` to drop its block; then add it to the
new component and apply again. Two site blocks for one name would stop the edge,
so apply refuses a domain another component still serves.

**Nothing is ever removed.** A component you delete from the file is listed as
"not in katap.json" and keeps running. Stopping it and removing its data is
deliberate work for you, not for apply.

**A deploy follows the file.** `katap check`, which every deploy runs, refuses a
component whose `.conf` disagrees with `katap.json` until `katap apply` has run,
and refuses a project's deploys while the file has a problem in that project (or
does not parse at all); a problem in another project's part holds only that
project. A rollback never reads it: the way back does not depend on a file being
edited.

Run apply as the deploy user (`sudo -u deploy`); it refuses to run as anyone who
does not own `/srv/projects`, so a project is never left owned by root.

## Without the file

`katap add <project> <type> <component> [domain...]` and `katap secrets <project>
<component>` still create one component by hand. You then set `image=` and
`source_repo=` in its `.conf` yourself. Apply leaves such components alone; it only
refuses to give one of their domains to another component.
