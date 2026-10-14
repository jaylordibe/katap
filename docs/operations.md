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
| Logs / status | `docker compose -p shop logs -f api` · `docker compose -p shop ps` |
| Back up now | `bin/katap backup shop`. Also nightly, by timer; 14 of each kind are kept per component (`KATAP_BACKUP_KEEP`) |
| Off-server copies | Install rclone and set `KATAP_RCLONE_REMOTE=remote:bucket/path` in `/etc/katap/katap.env`. Use an rclone `crypt` remote, because dumps hold personal data |
| Restore | `bin/katap restore shop api /srv/backups/shop/<file>.dump --confirm shop` |
| Change a site | Edit `/srv/projects/<project>/site.caddy`, then `bin/katap edge reload` |
| Change the TLS mode or edge address | Set it in `/srv/edge/edge.env` (it overrides `edge/edge.env` key by key), then `bin/katap edge up` |
| Scheduled work | Each project's per-minute run is cut off after 10 minutes (`KATAP_CRON_TIMEOUT`); put long work on the queue |
| Upgrade Katap | Run the installer again; see [Updating Katap](updating.md) |

Back up `/srv/katap.json`, `/srv/projects` and `/srv/secrets` together, or keep the
first two in a repository of your own. Never edit files in `/srv/katap`: a deploy
refuses to run while the tool has local modifications.

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

Every step either succeeds or leaves the current release serving.

| Step | What happens | If it fails |
|---|---|---|
| **Admit** | The key's forced command allows only its own component. One dispatch of a component at a time, and not again within a minute of the last | Refused; nothing changed |
| **Validate** | The tool is the installed release; the component's `.conf` matches `katap.json`; the digest belongs to its `image=`; no required secret is blank | Refused; nothing changed |
| **Verify** | `gh attestation verify`: built by `source_repo`'s `publish-image.yml`, from `main` for production. Runtime and migrate images come from one commit | Refused; nothing changed |
| **Pull** | `docker pull` by digest | Nothing changed |
| **Dump** | `pg_dump` of the component's database, kept with the nightly dumps | Refused; nothing changed |
| **Migrate** | One-shots in order. Laravel: `migrate`, then `permissions`. Nest: the migrate image (Prisma deploy + RBAC sync) | The current release keeps serving |
| **Roll out** | Services recreated in order (Laravel: worker, then API), waiting for each healthcheck. Caddy holds requests across the swap | **Automatic rollback** to the previous release |
| **Smoke check** | An HTTP check from inside the project network: 200, the expected body, no redirects followed | **Automatic rollback** |
| **Record** | The release joins the project's history | — |

The action then checks the public URL with the same smoke check. The deploy runs
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
> a hope, not a backup. Keep a copy of `/srv/secrets` somewhere safe as well: a
> dump without its `APP_KEY` cannot decrypt what the application encrypted.

## Upgrading PostgreSQL

To a new major version, never with the application serving in between:

1. `docker compose -p <project> stop <component> <component>-worker`;
2. `bin/katap backup <project>`;
3. change the image in `/srv/projects/<project>/<component>.yml`;
4. `docker volume rm <project>_<component>-db`;
5. `docker compose -p <project> up -d <component>-db` (the database alone);
6. `bin/katap restore <project> <component> <that dump> --confirm <project>`, which restores the data and starts the release again.

The database refuses to start an empty cluster beside an old one. A forgotten step
stops the database rather than serving an empty one.
