# Deploying from GitHub Actions

Your repository packages and builds the application; Katap deploys the image. The
repository holds no deployment files: no compose file, no Caddy configuration, no
settings. Those live with Katap on the server.

| | Where |
|---|---|
| The `Dockerfile` | Your repository |
| Build, scan, push | Your repository's workflow, with GitHub's standard actions |
| Deploy | One `jaylordibe/katap` step at the end of that workflow |

## 1. Package the application

The repository needs a `Dockerfile`. What each type of component expects from its
image:

| Type | Must | Official starting point |
|---|---|---|
| `nestjs-api` | Build from [nestjs-api](https://github.com/jaylordibe/nestjs-api): a runtime image (the last stage) and a `migrate` target | Its own `Dockerfile` |
| `laravel-api` | Build from [laravel-api](https://github.com/jaylordibe/laravel-api) | Its own `Dockerfile` |
| `node-ssr` (Next.js) | Listen on `0.0.0.0:3000`, answer `/` with 200 without a redirect, contain `wget` | Next.js's [`with-docker` example](https://github.com/vercel/next.js/tree/canary/examples/with-docker) (`output: "standalone"`), or Docker's [Next.js guide](https://docs.docker.com/guides/nextjs/containerize/) |
| `spa` (Angular, React, Vue) | Serve the built files on port 80, answer unknown paths with `index.html`, contain `wget` | Docker's guides for [Angular](https://docs.docker.com/guides/angular/containerize/), [React](https://docs.docker.com/guides/reactjs/containerize/) and [Vue](https://docs.docker.com/guides/vuejs/containerize/): build with Node, serve with nginx |

The `nestjs-api` and `laravel-api` templates are written for those two starter
repositories; an arbitrary NestJS or Laravel image does not meet their contract.
More detail: [What each template expects from an image](reference.md#what-each-template-expects-from-an-image).

## 2. Build and push

A repository that already builds and pushes its image in GitHub Actions keeps
that, unchanged. One that does not copies
[`examples/github-workflow.yml`](../examples/github-workflow.yml) to
`.github/workflows/`. It is GitHub's standard workflow from
[Publishing Docker images](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images):
- checkout, Buildx, log in to GHCR with the job's own token;
- `docker/build-push-action`, tagged with the commit;
- a vulnerability scan that stops the release on a fixable HIGH or CRITICAL finding.

Katap then needs the **digest** the build pushed. `docker/build-push-action`
gives it as `steps.<id>.outputs.digest`; pass it on as a job output, as the
example does (`image: ghcr.io/<owner>/<repo>@<digest>`).

A `nestjs-api` builds its `migrate` target too, from the same commit, and passes
that digest as well. The example shows how.

The image goes to `ghcr.io/<owner>/<repository>`, lowercased: that is the image
Katap expects for a component's `repo`, unless `image` in `/srv/katap.json`
says otherwise.

## 3. The deploy key and secrets

*On the server:*

```bash
katap deploy-key shop api
```

It makes a key that can deploy and roll back `shop/api`, and nothing else, and
prints three repository secrets (run it as shown: through the `katap` command,
the key is authorised for the `deploy` user):
- `KATAP_SSH_KEY`: the private key, every line;
- `KATAP_HOST`: the server's address;
- `KATAP_KNOWN_HOSTS`: the server's host key, so the workflow never trusts an unknown host.

Add them in the repository: **Settings → Secrets and variables → Actions → New
repository secret**. The private key is shown once; the server keeps only its
public half.

A **staging** component's secrets are printed as `KATAP_STAGING_SSH_KEY`,
`KATAP_STAGING_HOST` and `KATAP_STAGING_KNOWN_HOSTS`, so one repository can hold
both environments, on one server or two.

Adding secrets needs admin access to the repository. A repository owned by
another GitHub account, such as a startup's shared account, has that account add
them.

## 4. The deploy step

`katap deploy-key` prints the step with your project, component, release and
URL filled in:

```yaml
      - uses: jaylordibe/katap@<commit of your server's release> # vX.Y.Z
        with:
          host: ${{ secrets.KATAP_HOST }}
          known-hosts: ${{ secrets.KATAP_KNOWN_HOSTS }}
          ssh-key: ${{ secrets.KATAP_SSH_KEY }}
          project: shop
          component: api
          image: ${{ needs.build.outputs.image }}
          migrate-image: ${{ needs.build.outputs.migrate-image }}   # nestjs-api only
          url: https://api.example.com/api/health/readiness         # checked after the deploy
```

Put it in a job that runs after the build, with `permissions: packages: read`.

- **Pin it by commit,** never by a tag: it receives the deploy key, and a tag can be moved. Move the pin only after your server runs that release: see [Updating Katap](updating.md).
- **Private images need nothing extra.** The step hands the server this job's own GitHub token, on the SSH connection's input, for the one pull. It is never stored, and it expires with the job. Keep the deploy step in its own job with `permissions: packages: read`, as the example does: the server receives what the token may do.
- **The deploy keeps running on the server** if the workflow is cancelled or the connection drops. Its log is in `/srv/state/.dispatch/<project>/`.

Each push to `main` then deploys production. For staging, deploy from a
`staging` branch to a component with `"environment": "staging"` in
`/srv/katap.json`, using the `KATAP_STAGING_*` secrets.

## First deploy

- **laravel-api:** create the Passport personal access client, which sign-in needs:
  ```bash
  katap run shop api-artisan passport:client --personal --name='API Personal Access Client' --provider=users --no-interaction
  ```
  Never run `db:seed` or `UserSeeder` in production: it creates test users with a published password.
- **nestjs-api:** for a component named `api`, `katap run shop api-migrate yarn prisma:seed` creates the admin from `SEED_ADMIN_*`.

## Replacing a deploy key

A key leaked, or someone who had it left:

```bash
katap deploy-key shop api --replace
```

The old key stops working at once. Put the new `KATAP_SSH_KEY` (staging:
`KATAP_STAGING_SSH_KEY`) in the repository's secrets.

**The server's address changed:** update `host` in `/srv/katap.json`, then
update `KATAP_HOST` and `KATAP_KNOWN_HOSTS` (staging: `KATAP_STAGING_HOST` and
`KATAP_STAGING_KNOWN_HOSTS`) in each repository.

**The server was rebuilt** (new host key, no keys authorised): install Katap,
then run `katap deploy-key` for every component and update all three secrets.

## What the repository's secrets concede

Repository secrets work on every GitHub plan, private repositories included. Any
workflow in the repository can read them, from any branch, so anyone who can push
to the repository could deploy from a branch. On GitHub Free private
repositories, anyone who can push can already change `main`, so this costs little
in practice; the key still deploys only its own component. See
[Security model](security.md).
