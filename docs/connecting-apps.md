# Connecting applications

Each application repository deploys itself. It publishes an image, and its own
workflow asks the server to deploy that image, using a deploy key that can deploy
that one component and nothing else.

## 1. Publish an image

- **laravel-api and nestjs-api** forks already ship `.github/workflows/publish-image.yml`.
- **Anything else:** copy [`examples/publish-image.yml`](../examples/publish-image.yml) to `.github/workflows/publish-image.yml`. Keep that exact path: the server only accepts images attested by it.

`connect.sh` sets the repository variable `PUBLISH_ENABLED=true`, which turns
publishing on. Each push to `main` (and `staging`) then builds, scans and publishes
the image, with a build-provenance attestation.

What each type expects from its image is in [Reference](reference.md#what-each-template-expects-from-an-image).

## 2. Run connect.sh on your computer

```bash
curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/connect.sh | bash -s -- root@203.0.113.10
```

`katap apply` prints this line with your server's address. Add project names after
the address to connect only those projects. It needs:
- `ssh`, `ssh-keygen`, `jq`, `base64` and the [GitHub CLI](https://cli.github.com/), signed in (`gh auth login`) as an administrator of the repositories;
- SSH to the server as root, or as a user with passwordless sudo;
- the server already in your `known_hosts`. Connect once by hand, and check the fingerprint against your provider's console.

It reads the components `/srv/katap.json` declares from the server and checks every
value. It also checks two things:
- the release the server runs must be the commit GitHub has for that tag;
- the server's host key must be the one your `known_hosts` already trusts.

It then lists what it will change and asks first. For each component and
environment not yet connected:

1. It creates the repository's GitHub environment, limited to deployments from `main` (and `staging` for a staging environment). An environment that already exists must already be limited to exactly those branches: a wider limit would let a workflow on another branch read the key, so it is refused.
2. It makes a deploy key in a temporary directory on your computer.
3. It authorises the key's public half on the server for that component only, with `provision.sh --ci-key -`.
4. It sets the secrets and variables listed in the header of [`examples/deploy.yml`](../examples/deploy.yml), the key last.
5. It deletes the key. GitHub holds the only copy.

Then it prints one command, the same for every repository, that writes
`.github/workflows/deploy.yml`: [`examples/deploy.yml`](../examples/deploy.yml) at
the release the server runs, with its pin filled in. Run it in each repository's
checkout and commit the file.

An environment that already has `KATAP_SSH_KEY` keeps its key: only its address
and variables are brought up to date, for example after a domain changed. To
replace a key, delete that secret and run it again; the old key stays authorised
on the server until you remove its line from `~deploy/.ssh/authorized_keys`.

A repository deploys one component per environment, so `katap.json` never lists
one repository twice for one environment.

## 3. Finish in GitHub

In each repository:

1. **Commit `.github/workflows/deploy.yml`** with the command `connect.sh` printed.
2. **Protect production.** In Settings → Environments → production:
   - add required reviewers;
   - turn on "Prevent self-review".

   `connect.sh` limits deployment branches but leaves approval rules to you, and prints the link.
3. **Protect `main`** with a ruleset: require a pull request, block force pushes, no bypass. Whoever can change the deploy workflow on `main` can use the key.

After that:
- **Staging** deploys after each successful publish from the `staging` branch. The `workflow_run` trigger in `deploy.yml` must list your publish workflow's exact `name:`, and `deploy.yml` must be on the default branch, where GitHub reads `workflow_run` triggers.
- **Production** deploys from **Actions → Deploy → Run workflow → production**, once a reviewer approves.

### First deploy only

- **laravel-api:** create the Passport personal access client, which sign-in needs:
  ```bash
  sudo -iu deploy /srv/katap/bin/katap run shop api-artisan passport:client --personal --name='API Personal Access Client' --provider=users --no-interaction
  ```
  Never run `db:seed` or `UserSeeder` in production: it creates test users with a published password.
- **nestjs-api:** for a component named `api`, `katap run shop api-migrate yarn prisma:seed` creates the admin from `SEED_ADMIN_*`.

## Private repositories

Attestations need a public repository, or a GitHub plan that offers them on
private ones (set `ATTEST_PROVENANCE=true` in the publish workflow). Without them,
set `"provenance": "none"` for that component in `/srv/katap.json`. The server then
deploys anything pushed to that image repository, and logs a warning on every
deploy.

If the images are private, log the deploy user in to the registry with a token
that can only read packages:

```bash
sudo -u deploy docker login ghcr.io -u <you> --password-stdin
```

## Doing it by hand

What `connect.sh` does, step by step, for one repository and environment:

```bash
# On your computer: a key for this repository and environment.
ssh-keygen -t ed25519 -N '' -f shop-api-production

# On the server: authorise its public half for that one component.
sudo /srv/katap/host/provision.sh --ci-key "$(cat shop-api-production.pub)" \
    --ci-env production --ci-project shop --ci-component api

# On the server: the line for KATAP_KNOWN_HOSTS, under the address deploys use.
echo "<host> $(cut -d' ' -f1-2 /etc/ssh/ssh_host_ed25519_key.pub)"
```

Then, in the repository:
1. Create the environment.
2. Set the secrets and variables the [`examples/deploy.yml`](../examples/deploy.yml) header lists. `KATAP_SSH_KEY` is the whole private key file.
3. Copy that file to `.github/workflows/deploy.yml`, replacing the all-zero commit with the commit of the Katap release the server runs (`cat /etc/katap/release`).
4. Delete the private key from your computer.

## Pinning the action

Pin the action by commit, never by tag: `uses: jaylordibe/katap@<40-character commit> # v1.1.0`.
The action receives the deploy key, and a tag can be moved. It runs no other
action, so that commit is all the code it runs.

Move the pin only after your server runs that release: see
[Updating Katap](updating.md). Running `connect.sh` again after an upgrade prints
the command with the new pin.
