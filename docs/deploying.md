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

## 2. The workflow

The repository's workflow builds and pushes the image, then deploys it with one
pinned `jaylordibe/katap` step. Use whichever fits:

- **A repository made from laravel-api or nestjs-api** already builds, scans and
  pushes in `.github/workflows/publish-image.yml`. Add the example's `deploy` and
  `deploy-staging` jobs at the end of that file, as they are (a nestjs-api
  uncomments their `migrate-image` line), and set the repository variable
  `PUBLISH_ENABLED` to `true`. Its `publish` job outputs the pushed digests the
  jobs read; a copy made before it did takes those `outputs:` lines from the
  starter's current `publish-image.yml`.
- **Any other repository** copies
  [`examples/github-workflow.yml`](../examples/github-workflow.yml) to
  `.github/workflows/`, unchanged (a nestjs-api-style image uncomments its migrate
  lines). It is GitHub's standard workflow from
  [Publishing Docker images](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images),
  plus the deploy jobs:
  - checkout, Buildx, log in to GHCR with the job's own token;
  - `docker/build-push-action`, tagged with the commit;
  - a vulnerability scan that stops the release on a fixable HIGH or CRITICAL finding.
- **Any repository that already builds and pushes its image** keeps its build
  job, makes it output the pushed digest (`docker/build-push-action` gives it as
  `steps.<id>.outputs.digest`; output `image: ghcr.io/<owner>/<repo>@<digest>`),
  and adds the example's `deploy` and `deploy-staging` jobs with `needs:` and
  `needs.<job>` set to that job's name.

The image goes to `ghcr.io/<owner>/<repository>`, lowercased: that is the image
Katap expects for a component's `repo`, unless `image` in `/srv/katap.json`
says otherwise.

Nothing in the workflow names your server or project: those come from the
repository's secrets and variables. A push to `main` deploys production; a push to
`staging` deploys staging, each only once its variables are set. Until then the
workflow builds and pushes, and deploys nothing.

## 3. The deploy key, secrets and variables

*On the server:*

```bash
katap deploy-key shop api
```

It makes a key that can deploy and roll back `shop/api`, and nothing else, and
prints what to add in the repository, under **Settings → Secrets and variables →
Actions**:

| Kind | Name | Value |
|---|---|---|
| Secret | `KATAP_SSH_KEY` | The private key, every line |
| Secret | `KATAP_HOST` | The server's address |
| Secret | `KATAP_KNOWN_HOSTS` | The server's host key, so the workflow never trusts an unknown host |
| Variable | `KATAP_PROJECT` | `shop` |
| Variable | `KATAP_COMPONENT` | `api` |
| Variable | `KATAP_URL` | Optional: a public URL checked after each deploy |

Run it as shown, through the `katap` command: the key is authorised for the
`deploy` user. The private key is shown once; the server keeps only its public
half.

A **staging** component's are named `KATAP_STAGING_…` (`KATAP_STAGING_SSH_KEY`,
`KATAP_STAGING_PROJECT`, and so on), so one repository can hold both
environments, on one server or two.

Adding secrets and variables needs admin access to the repository. A repository
owned by another GitHub account, such as a startup's shared account, has that
account add them.

## 4. The deploy step

Each deploy job in [`examples/github-workflow.yml`](../examples/github-workflow.yml)
holds one `jaylordibe/katap` step. Its inputs are the repository's secrets and
variables of step 3, and the image the `publish` job pushed, by digest.

- **Pinned by commit,** never by a tag: the step receives the deploy key, and a tag can be moved. With Dependabot's `github-actions` updates on (a `.github/dependabot.yml`), the pin moves to each new Katap release; any release of your server's major version works with it (`katap deploy-key` names the major). See [Updating Katap](updating.md).
- **Private images need nothing extra.** The step hands the server its job's own GitHub token, on the SSH connection's input, for the one pull. It is never stored, and it expires with the job. Each deploy job holds only `permissions: packages: read`: the server receives what the token may do.
- **The deploy keeps running on the server** if the workflow is cancelled or the connection drops. Its log is in `/srv/state/.dispatch/<project>/`.

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
