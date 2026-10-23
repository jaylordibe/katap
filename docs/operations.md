# Day to day

Run these on the server as the deploy user, from the tool directory:

```bash
sudo -iu deploy
cd /srv/katap
```

| Task | Command |
|---|---|
| Add a project or component | Add it to `/srv/katap.json` (as root), then `bin/katap apply`; see [The projects file](projects-file.md) |
| Roll back | `bin/katap rollback shop api`: back to the release before the one serving; run it again to go further back. It never runs migrations backwards, so keep migrations expand-only |
| One-off command | `bin/katap run shop api-artisan <args>`: as the application user, never root |
| Logs / status | `docker compose -p shop logs -f api` · `docker ps --filter label=com.docker.compose.project=shop` (running containers only; check every expected service appears) |
| Back up now | `bin/katap backup shop`. Also nightly, by timer; 14 of each kind are kept per component (`KATAP_BACKUP_KEEP`) |
| Off-server copies | Not on by default; see [What a backup covers](#what-a-backup-covers) |
| Restore | `bin/katap restore shop api /srv/backups/shop/<file>.dump --confirm shop` |
| Change a site | Edit `/srv/projects/<project>/site.caddy`, then `bin/katap edge reload` |
| Change the TLS mode or edge address | Set it in `/srv/edge/edge.env` (it overrides `edge/edge.env` key by key), then `bin/katap edge up` |
| Scheduled work | Each project's per-minute run is cut off after 10 minutes (`KATAP_CRON_TIMEOUT`); put long work on the queue |
| Upgrade Katap | Run the installer again; see [Updating Katap](updating.md) |

Back up `/srv/katap.json`, `/srv/projects` and `/srv/secrets` together, or keep the
first two in a repository of your own. Never edit files in `/srv/katap`: a deploy
refuses to run while the tool has local modifications.

## What a backup covers

`katap backup` (nightly through `katap-backup.timer`, around 03:00 server time, and
before every deploy) dumps **each component's PostgreSQL database** to
`/srv/backups/<project>/`. Each dump has a `.images` file beside it that records the
release serving at the time. The newest 14 of each kind (`scheduled`, `predeploy`,
`prerestore`) are kept per component (`KATAP_BACKUP_KEEP`).

It does not cover:
- Redis (queues, caches, sessions);
- files the application writes inside its containers or to other Docker volumes. Keep uploads in object storage;
- `/srv/secrets`, `/srv/katap.json`, `/srv/projects`, `/etc/katap` or Caddy's certificates.

Those need their own copies: keep `/srv/secrets` and the project files somewhere
safe, and the uploads in object storage. A disk snapshot from your provider copies
everything on the disk, but a database copied mid-write isn't guaranteed
consistent. Treat snapshots as an addition to the dumps, not a replacement.

**The dumps stay on this server** unless you set up off-server copies with rclone.
Creating a bucket configures nothing by itself.

### Off-server copies with rclone

After every dump, Katap runs `rclone copy` for the dump and its `.images` file, as
the `deploy` user, into `$KATAP_RCLONE_REMOTE/<project>/`.

1. **Install [rclone](https://rclone.org/).** *Server, as your administrator.* Provisioning doesn't install it. rclone's own [installer](https://rclone.org/install/) is current; distribution packages are often out of date:
   ```bash
   sudo -v ; curl https://rclone.org/install.sh | sudo bash
   ```
2. **Create a storage credential** at your provider. It needs read, list and write access to one bucket, and nothing administrative. Katap's copies never delete anything.
3. **Configure two remotes as `deploy`.** *Server SSH session.* The configuration goes to `/home/deploy/.config/rclone/rclone.conf`, where the backups look for it.
   ```bash
   sudo -iu deploy rclone config
   ```
   - `offsite`: the storage remote, of your provider's type, with the credential from step 2.
   - `offsite-crypt`: type **crypt**, with `remote = offsite:your-bucket/katap`. Use standard filename encryption, and set both a password and a salt (rclone calls it password2). Dumps hold personal data, so encrypt them.
4. **Keep the crypt password and salt safe, off the server**, in a password manager, together with a copy of `rclone.conf`. Without them, the encrypted copies can't be read. Changing them later makes existing copies unreadable. rclone only obscures these passwords in its config file; it doesn't encrypt them ([rclone crypt](https://rclone.org/crypt/)). Don't set an rclone configuration password: Katap's nightly run has no way to supply it, so the copies would fail.
5. **Point Katap at the crypt remote.** In `/etc/katap/katap.env` (`sudo nano /etc/katap/katap.env`):
   ```text
   KATAP_RCLONE_REMOTE=offsite-crypt:dumps
   ```
   Copies then land in `offsite-crypt:dumps/shop/`. Without encryption, the value would be `offsite:your-bucket/katap`, which isn't recommended.
6. **Check both files arrive.** *Server, as `deploy`:*
   ```bash
   /srv/katap/bin/katap backup shop
   rclone ls offsite-crypt:dumps/shop/
   ```
   Both the newest `….dump` and its `….dump.images` should be listed, with the same sizes as in `/srv/backups/shop/`.

**Retention:**
- **On the server:** the newest `KATAP_BACKUP_KEEP` dumps (14 by default) of each kind are kept per component.
- **Remote:** Katap never deletes remote copies, because it only runs [`rclone copy`](https://rclone.org/commands/rclone_copy/), so they accumulate. Set a lifecycle or retention rule at your storage provider.

**Monitoring:** Katap sends no alerts.
- A failed dump or copy fails the nightly `katap-backup.service`.
- Before a deploy, a failed copy is only logged, and the deploy goes ahead.
- Check with `systemctl status katap-backup.service`, `systemctl --failed`, and `journalctl -u katap-backup.service --since yesterday`. Wire those into your own monitoring.

**Getting a copy back.** *Server, as `deploy`:*

```bash
D=api-20261023T030000Z-scheduled.dump     # the file name, from: rclone ls offsite-crypt:dumps/shop/
rclone copy "offsite-crypt:dumps/shop/$D" /srv/backups/shop/
rclone copy "offsite-crypt:dumps/shop/$D.images" /srv/backups/shop/
```

Then follow [Restoring](#restoring). `restore` needs the `.images` file next to
the dump. To check that a copy can be read, without touching any data, list its
contents:

```bash
docker exec -i shop-api-db-1 pg_restore --list < "/srv/backups/shop/$D" > /dev/null && echo readable
```

That proves the file is a readable dump, not that a restore will succeed. Only a
real restore, on a separate server or project, proves that.

## Is one server enough?

Yes, for side projects, internal tools and low-traffic products. There are two costs:

- **Shared fate.** One server down means every project is down. Backups make that recoverable; nothing here makes it highly available.
- **Memory is the limit.** Approximate steady state per component:

  | Component | RAM |
  |---|---|
  | laravel-api API (php-fpm, up to 20 workers in the base image) | 150 MB idle, up to ~1 GB (`mem_limit`) |
  | laravel-api Horizon worker | 100–300 MB |
  | nestjs-api | 150–400 MB |
  | PostgreSQL / Redis, per project | 50–100 MB / ~10 MB |
  | spa / Caddy | ~10 MB / ~30 MB |

  A 4 GB VPS holds two or three small projects. Lower `mem_limit` in a project's compose file to fit more. When a project outgrows its share, move it to its own server or a managed database; its images and settings go with it unchanged.

## What a deploy does

A failure before the **Migrate** step changes nothing. From **Migrate** on, the
database may already have changed, and nothing undoes a migration: keep migrations
backward compatible (expand-only), so the previous release still runs on the new
schema, and use the pre-deploy dump with `restore` when that isn't enough.

| Step | What happens | If it fails |
|---|---|---|
| **Admit** | The key's forced command allows only its own component. One dispatch of a component at a time, and not again within a minute of the last | Refused; nothing changed |
| **Validate** | The tool is the installed release; the component's `.conf` matches `katap.json`; the digest belongs to its `image=`; no required secret is blank | Refused; nothing changed |
| **Verify** | `gh attestation verify`: built by `source_repo`'s `publish-image.yml`, from `main` for production. Runtime and migrate images come from one commit | Refused; nothing changed |
| **Pull** | `docker pull` by digest | Nothing changed |
| **Dump** | `pg_dump` of the component's database, kept with the nightly dumps | Refused; nothing changed |
| **Migrate** | One-shots in order. Laravel: `migrate`, then `permissions`. Nest: the migrate image (Prisma deploy + RBAC sync) | The current release keeps serving; migrations that already ran stay applied |
| **Roll out** | Services recreated in order (Laravel: worker, then API), waiting for each healthcheck. Caddy holds requests across the swap | **Automatic rollback** to the previous images; the schema stays migrated. On a component's first deploy there is nothing to roll back to. If the rollback itself fails, the log says `ROLLBACK FAILED` and the component may be down |
| **Smoke check** | An HTTP check from inside the project network: 200, the expected body, no redirects followed | **Automatic rollback** |
| **Record** | The release joins the project's history | — |

The action then checks the public URL with the same smoke check. A failure there
fails the workflow, but the new release stays serving: nothing rolls back. The
first deploy of a component takes no pre-deploy dump, because it has no data yet.
The deploy runs
detached on the server, so a cancelled workflow or a dropped connection never stops
it halfway. Its log is in `/srv/state/.dispatch/<project>/`.

## Restoring

`restore` puts back the database **and the release that was serving when the dump
was taken**. It stops the component and dumps the current data first. It restores
into a new database and swaps it in only when complete, so a failed restore changes
nothing. It also empties the component's Redis, whose queued jobs and caches
described the replaced data.

> [!IMPORTANT]
> **Test a restore before you need one.** A backup that has never been restored is
> a hope, not a backup. Back up `/srv/secrets` separately as well. Laravel needs the
> original `APP_KEY` to decrypt application-encrypted values restored from the
> database. The database dump itself is not encrypted by `APP_KEY`; encrypting
> backup files (an rclone `crypt` remote) is separate.

## Upgrading PostgreSQL

**A minor version** (18.6 → 18.7) uses the same data files. Pin the new digest in
the `<component>-db` service's `image:`, then recreate that container (step 6 below
shows how).

**A major version** (18 → 19) can't open the old cluster's files. Katap supports a
**logical dump and restore** into a new, empty cluster, using its own `katap
backup` and `katap restore`. It doesn't run `pg_upgrade`, and the procedure below
doesn't mix the two approaches.

> [!WARNING]
> This procedure is not covered by Katap's test suite. Rehearse it on a copy (a
> staging project, or a snapshot of the server) before running it on real data.

### Why the new major gets its own volume

The data volume is mounted at `/var/lib/postgresql`, and Katap's database
entrypoint refuses to initialise an empty cluster in a volume that already holds
another major's cluster, which it detects as a `<major>/docker` directory, the layout of the `postgres:18` and later images (`lib/postgres-entrypoint.sh`). So the new major gets a
**new volume**. The old volume stays untouched until the new database is
verified, and it's your way back.

Never delete the only copy of the old volume, and never use `docker compose down -v`
on a project: it removes every volume of every component in it.

### What restore does on the new cluster

On first start, the new cluster creates the `app` role and the `app` database from
the passwords in `/srv/secrets/<project>/<component>.db.env`. `katap restore` then,
in order:

1. stops the component's `rollout=` services;
2. dumps the new, still empty database as a safety copy;
3. builds `app_restore` with `lib/app-database.sql` and restores the dump into it as the `postgres` superuser, in one transaction;
4. swaps it in as `app`;
5. records the release named in the dump's `.images` file;
6. empties the component's Redis;
7. rolls the release out again, waiting for healthchecks and the smoke check.

### Limits to plan for

- **Dump version.** The dump comes from the old server's own `pg_dump`. PostgreSQL accepts that, but recommends dumping with the newer version's `pg_dump` for upgrades. Katap has no way to do that, so rehearse.
- **What the dump holds.** Only the `app` database. Roles other than `app`, and settings made with `ALTER DATABASE … SET` or `ALTER ROLE … SET`, aren't included and must be recreated by hand.
- **Extensions.** Every extension in the database must exist in the new image. The official image ships PostgreSQL's contrib modules; others, such as PostGIS or pgvector, don't.
- **A failed restore restarts the application on the new, empty database.** Restore's failure path brings the release back up against the database it just failed to fill. If step 7 fails, go straight to [If the upgrade fails](#if-the-upgrade-fails).
- **Queued jobs are lost.** Restore empties Redis, so drain the queue before step 3.
- **Downtime** runs from step 3 until step 8 succeeds.
- **Every project's scheduled jobs and nightly dumps pause** while the timers are stopped (steps 2 to 9).
- **Deploy keys stay valid.** Disabling the deploy workflow stops normal deploys; it doesn't revoke the keys.

### Placeholders and where commands run

| Placeholder | Example | Meaning |
|---|---|---|
| `<project>` / `<component>` | `shop` / `api` | The component whose database you upgrade |
| `<new image>` | `postgres:19.1@sha256:…` | The new major, pinned by digest; `katap check` refuses a tag alone |
| `<new volume>` | `api-db-pg19` | A volume name not used in the project yet |
| `your-org/shop-api` | | Each repository that deploys to this project |

Server commands run in an SSH session as your administrator (`sudo` lines) or as
the deploy user (after `sudo -iu deploy`).

### Before you start

- Find the new image's digest (*server, either user*): `docker buildx imagetools inspect postgres:19.1` prints a `Digest:` line.
- Check where the new image keeps its data: `docker image inspect <new image> --format '{{json .Config.Volumes}} {{.Config.Env}}'`. Both the declared volume and `PGDATA` must be at or under `/var/lib/postgresql`, where Katap mounts the named volume, as in `postgres:18`. An image that declares its volume elsewhere (`postgres:17` and earlier use `/var/lib/postgresql/data`) would put the cluster in an anonymous volume, outside Katap's named volume. Those data can be lost when the container is replaced, for example when its image changes.
- Check what writes to this database (*server*): `grep -E '^(rollout|cron|predeploy|backup)=' /srv/projects/<project>/<component>.conf`.
  - `rollout=` lists the long-running services: for laravel-api, `<component>-worker <component>`; for nestjs-api, `<component>`, which runs its queue worker in-process.
  - `cron=` is the per-minute scheduler.
  - `predeploy=` runs only during deploys.
  - Other components normally have databases of their own.
- Rehearse, and announce the downtime.

### 1. Stop deploys

*Your computer.* For each repository that deploys to the project:

```bash
gh workflow disable Deploy --repo your-org/shop-api
gh run list --repo your-org/shop-api --workflow Deploy --status in_progress   # must print nothing
```

Don't approve any deploy still waiting for review.

### 2. Stop scheduled work

*Server, as your administrator.*

```bash
sudo systemctl stop katap-cron.timer katap-backup.timer
```

A job already running finishes on its own. Step 4's backup waits for it, because
both take the project's lock.

### 3. Stop the application

*Server, as the deploy user.* Open a shell, then define a helper that runs Docker
Compose with exactly the files, settings and image digests `bin/katap` uses:

```bash
sudo -iu deploy
P=shop C=api                      # <project> and <component>
kcompose() {
    local files=() f
    for f in /srv/projects/"$P"/*.yml; do files+=(-f "$f"); done
    KATAP_ROOT=/srv/katap KATAP_PROJECT="$P" KATAP_SECRETS=/srv/secrets/"$P" \
        docker compose --project-name "$P" --project-directory /srv/projects/"$P" \
        --env-file /srv/state/"$P"/images.env "${files[@]}" "$@"
}
```

Stop the API first, so no new requests or jobs arrive:

```bash
kcompose stop "$C"
```

For laravel-api, wait until the queue is empty, then stop the worker. How you
check the queue depends on your application.

```bash
kcompose stop "$C-worker"
```

**Downtime starts here.**

**Checkpoint:** `docker ps --filter label=com.docker.compose.project=$P` shows
`$C-db` and `$C-redis` running, and no `$C`, `$C-worker` or scheduler container.

### 4. Take the final dump and copy it off the server

*Server, as the deploy user.*

Take the dump, and pick only a dump written by this attempt. The marker file
records when the attempt started, so an older dump can never be picked by mistake:

```bash
MARK="$(mktemp)"
DUMP=''
if /srv/katap/bin/katap backup "$P"; then
    DUMP="$(find /srv/backups/"$P" -maxdepth 1 -name "$C-*-scheduled.dump" -newer "$MARK" | sort | tail -n 1)"
fi
[ -n "$DUMP" ] && echo "DUMP=$DUMP" || echo "STOP: no dump from this attempt; do not continue"
```

Then check that this dump is complete, readable, and recorded with the release
serving now:

```bash
[ -n "$DUMP" ] && [ -s "$DUMP" ] && cmp -s "$DUMP.images" /srv/state/"$P"/images.env \
  && kcompose exec -T "$C-db" pg_restore --list < "$DUMP" > /dev/null \
  && sha256sum "$DUMP" "$DUMP.images" \
  || echo "STOP: the dump or its .images file is missing, unreadable, or not from the release serving now"
```

**Checkpoint:** continue only if the first block printed `DUMP=…` and the second
printed two checksums with no `STOP`. A failed backup, or a `.images` file that
differs from `/srv/state/<project>/images.env`, means this isn't the dump to
upgrade from.

`katap backup` dumps every component of the project that has a database, and fails
if any of them fails. Note a
few row counts too (`kcompose exec -T "$C-db" psql -U postgres -d app -Atc 'select
count(*) from users'`), so you can compare them after the restore.

*Your computer.* Copy the dump, its `.images` file and the project's secrets
off the server. The secrets hold the passwords the new cluster will use, the
application's `APP_KEY`, and the database TLS certificate. Then compare checksums:

```bash
D=api-20261023T030000Z-scheduled.dump    # the file name in DUMP= above
for f in "$D" "$D.images"; do
    ssh admin@203.0.113.10 sudo cat "/srv/backups/shop/$f" > "$f"
done
ssh admin@203.0.113.10 sudo tar -C /srv/secrets -czf - shop > shop-secrets.tgz
shasum -a 256 "$D" "$D.images"
```

Keep `shop-secrets.tgz` encrypted and private.

**Checkpoint:** don't continue until the checksums match the server's.

### 5. Point the database at a new volume and image

*Server, as the deploy user.* Keep a copy of the compose file. Its name must not end
in `.yml`, because Katap loads every `*.yml` in the project directory:

```bash
cp /srv/projects/"$P"/"$C".yml /srv/projects/"$P"/"$C".yml.before-upgrade
nano /srv/projects/"$P"/"$C".yml
```

Make three edits:

1. In the `<component>-db` service, set `image:` to `<new image>`.
2. In the same service, change the volume line `- <component>-db:/var/lib/postgresql` to `- <new volume>:/var/lib/postgresql`.
3. Under the top-level `volumes:` key at the end of the file, add `  <new volume>:`.

Then:

```bash
diff /srv/projects/"$P"/"$C".yml.before-upgrade /srv/projects/"$P"/"$C".yml
/srv/katap/bin/katap check "$P"
```

`katap check` must pass. The diff should show only those three edits.

### 6. Start the new database alone

```bash
if kcompose up -d --wait --wait-timeout 300 "$C-db"; then
    kcompose exec -T "$C-db" psql -U postgres -d app -Atc 'select version()'
    docker volume ls --filter name="${P}_${C}-db"     # the old volume is still there
else
    echo "STOP: the new database did not become healthy; see If the upgrade fails"
fi
```

Compose recreates the database container on the new volume and waits, for up to 5
minutes, until its healthcheck passes. The old volume is no longer attached to any
container, and it isn't changed.

**Checkpoint:** continue to step 7 only if the version shows the new major and no
`STOP` was printed. Otherwise run `kcompose logs --tail=100 "$C-db"`, and go to
[If the upgrade fails](#if-the-upgrade-fails).

### 7. Restore into the new cluster

```bash
/srv/katap/bin/katap restore "$P" "$C" "$DUMP" --confirm "$P"
```

**Success** ends with `restored '<project>/<component>' from <file>, with the
release that wrote it.` On any failure, go to [If the upgrade fails](#if-the-upgrade-fails).

### 8. Verify

- `select version()` (step 6) names the new major.
- Your row counts from step 4 match.
- `docker ps --filter label=com.docker.compose.project=$P` shows every service `(healthy)`.
- The public URL answers, and you can sign in and read data, including values the application encrypts.

### 9. Resume

*Server, as your administrator*, then *your computer*:

```bash
sudo systemctl start katap-cron.timer katap-backup.timer
gh workflow enable Deploy --repo your-org/shop-api
```

Then take a dump on the new version and check that it works:
`/srv/katap/bin/katap backup <project>`, as the deploy user.

Keep the old volume, the `.before-upgrade` file and the off-server dump until
you're confident. To remove the old volume later (irreversible), first confirm that
`docker ps -a --filter volume=<project>_<component>-db` lists nothing, then run
`docker volume rm <project>_<component>-db`.

### If the upgrade fails

The old volume still holds the cluster exactly as it was at step 4. *Server, as
the deploy user*, with the helper from step 3:

```bash
kcompose stop "$C" "$C-worker"          # nestjs-api: "$C" only
cp /srv/projects/"$P"/"$C".yml.before-upgrade /srv/projects/"$P"/"$C".yml
if kcompose up -d --wait --wait-timeout 300 "$C-db"; then     # the old image on the old volume
    for s in $(sed -n 's/^rollout=//p' /srv/projects/"$P"/"$C".conf); do
        kcompose up -d --wait --wait-timeout 300 "$s" || { echo "STOP: $s did not become healthy"; break; }
    done
else
    echo "STOP: the old database did not start; check: kcompose logs --tail=100 $C-db"
fi
```

Start the application only after the old database is healthy. If a `STOP` is
printed, the old volume is still intact: find the cause in the logs before trying
again.

`/srv/state/<project>/images.env` names the release that was serving before
step 3, even if the restore got as far as recording the dump's release: they're the
same one. Then resume as in step 9.

Anything written to the new database after step 7 isn't in the old one. If the
restore emptied Redis, the jobs it held are gone.
