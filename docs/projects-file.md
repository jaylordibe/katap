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

## Application settings

`katap apply` writes each component's settings to `/srv/secrets/<project>/<component>.env`
(mode 0600, owned by `deploy`), from its template's `templates/<type>.env.spec`:

- **Generated** values are made once on the server: keys, database and Redis passwords, Passport keys and so on. Never change them on a running application: a new `APP_KEY` or database password breaks existing data and logins.
- **Derived** values come from `katap.json`: `APP_URL` from the first domain, and the frontend URL and CORS origins from the project's single `spa` or `node-ssr` component with domains.
- **Yours to supply** are left empty under a `# katap:required` marker, and a deploy is refused while any of them is empty.

| Template | Required values you supply | Where accepted values are documented |
|---|---|---|
| `laravel-api` | `MAIL_MAILER`, `MAIL_FROM_ADDRESS`; `APP_FRONTEND_URL` and `CORS_ALLOWED_ORIGINS` when the project has no single frontend | [laravel-api DEPLOYMENT.md](https://github.com/jaylordibe/laravel-api/blob/main/DEPLOYMENT.md), "Environment contract" and "Object storage contract" |
| `nestjs-api` | `EMAIL_PROVIDER`, `EMAIL_FROM`, `SMS_PROVIDER`, `STORAGE_PROVIDER`, `TURNSTILE_WEB_SECRET`, `TURNSTILE_MOBILE_SECRET`, `SEED_ADMIN_EMAIL`; `WEB_BASE_URL` and `CORS_ORIGIN` when the project has no single frontend | [nestjs-api deployment contract](https://github.com/jaylordibe/nestjs-api/blob/main/docs/deployment/README.md), "Environment contract" |
| `node-ssr` | None. Add the runtime variables your server reads | Your application |
| `spa` | None. A static site reads no runtime settings; see [build-time settings](reference.md#build-time-and-runtime-settings) | Your application |

**Edit the file** as the deploy user (*server SSH session*):
`sudo -u deploy nano /srv/secrets/<project>/<component>.env`. Add the values the
starter's documentation asks for, such as mail credentials and the settings for a
storage provider. Run `katap apply` again to list required values that are still
empty, by name only.

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

Redeploy the build that's running now. Don't redeploy `main`: `main` is a moving tag
and may point to a newer build. The Deploy workflow takes a **tag**, not a digest, so
you need the running build's `sha-<full commit>` tag. Katap records only the
digest, and its deploy log keeps just the first 12 characters of the commit. The
full commit comes from the image's attestation.

*Server SSH session, as `deploy`* (`sudo -iu deploy`). The placeholders are
`shop`/`api` and `your-org/shop-api`:

```bash
grep '^IMAGE_API' /srv/state/shop/images.env    # IMAGE_API=ghcr.io/your-org/shop-api@sha256:…, plus IMAGE_API_MIGRATE for a nestjs-api
REF="$(sed -n 's/^IMAGE_API=//p' /srv/state/shop/images.env)"
COMMIT="$(GH_TOKEN="$(sed -n 's/^KATAP_GH_TOKEN=//p' /etc/katap/katap.env | tail -n 1)" \
  gh attestation verify "oci://$REF" --repo your-org/shop-api \
  --signer-workflow your-org/shop-api/.github/workflows/publish-image.yml --format json \
  | jq -r '.[0].verificationResult.signature.certificate.sourceRepositoryDigest')"
echo "commit: $COMMIT"
```

That prints the full 40-character commit, from the same field Katap reads. Before
using its tag, confirm that the tag still names the running digest:

```bash
echo "running: ${REF#*@}"
docker buildx imagetools inspect "ghcr.io/your-org/shop-api:sha-$COMMIT" | grep '^Digest:'
```

- **The digests match:** deploy with **Run workflow**, choosing the same environment and the tag `sha-` followed by that commit.
- **A nestjs-api** derives its migrate image from the same tag. Check `ghcr.io/your-org/shop-api-migrate:sha-<commit>` the same way against `IMAGE_API_MIGRATE`.
- **Any digest differs, or a command fails:** stop. That tag doesn't reproduce the running build.

This is a normal deploy. It verifies provenance again, takes a pre-deploy dump,
runs the template's pre-deploy steps again (migrations, which apply nothing when
none are pending, and steps such as laravel-api's permissions sync), rolls out with
healthchecks and the smoke check, and rolls back automatically if the release
never becomes healthy.

**Limits:**
- For a component with `"provenance": "none"` there's no attestation, so the commit can't be recovered this way. Use the commit from the Deploy run that put this build live: its log prints the digest (`Deploying: …`), and its inputs show the tag. If that tag was `main`, find the publish run whose summary shows the same digest.
- If the `sha-` tag has been deleted from the registry, the Deploy workflow can't select that build at all.

## Without the file

`katap add <project> <type> <component> [domain...]` and `katap secrets <project>
<component>` still create one component by hand. You then set `image=` and
`source_repo=` in its `.conf` yourself. Apply leaves such components alone; it only
refuses to give one of their domains to another component.
