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

Copying the example doesn't make the repository deployable by itself:
- **It builds the repository's own `Dockerfile`** and creates none. The image must meet its template's contract: see [What each template expects from an image](reference.md#what-each-template-expects-from-an-image).
- **Its `test` job is a placeholder** that only prints `Run the test suite here.` Replace it with your real tests before you rely on a green run. The `publish` job waits for it, but it can't fail.
- **A new GHCR package is private,** even when the repository is public. Before the server can verify or pull the image, either make the package public (the package's **Package settings → Danger Zone → Change visibility → Public**), or give the server a registry login: see [Private images](#private-images).

## 2. Run connect.sh on your computer

```bash
curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/connect.sh | bash -s -- root@203.0.113.10
```

`katap apply` prints this line with your server's address and `root@`. Use whichever
administrator account you log in with, for example `admin@203.0.113.10`, or a
`Host` alias from `~/.ssh/config`. An alias is how you pick a non-default key: the
script has no key option. See [The SSH keys involved](../README.md#the-ssh-keys-involved).
Add project names after the address to connect only those projects. It needs:
- `bash`, `curl`, `ssh`, `ssh-keygen`, `jq` and the [GitHub CLI](https://cli.github.com/), signed in (`gh auth login`) as an administrator of the repositories;
- SSH to the server as root, or as a user with passwordless sudo. It runs `ssh` with `BatchMode=yes` and `sudo -n`, so nothing can prompt: a passphrase-protected key must already be in `ssh-agent`, and a login that needs a password or a second factor fails;
- the server's ed25519 host key already in your `known_hosts`. Connect once by hand, and check the fingerprint against your provider's console;
- `host` set in `/srv/katap.json`. That's the address GitHub Actions deploys to, always on port 22.

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

### Running connect.sh again

Run it again after adding a component, changing `/srv/katap.json`, upgrading the
server, or changing its address. It doesn't skip what's already connected:

- **An environment that already has `KATAP_SSH_KEY`** keeps that key, but connect still:
  - checks the environment's deployment branches;
  - sets `KATAP_HOST` and `KATAP_KNOWN_HOSTS` again, plus the variables `KATAP_PROJECT`, `KATAP_COMPONENT` and `KATAP_IMAGE`;
  - sets `KATAP_MIGRATE_IMAGE` and `KATAP_URL`, or deletes them when they no longer apply;
  - sets the repository variable `PUBLISH_ENABLED=true` again.
- **An environment without the key** is connected from scratch.
- **The `deploy.yml` command** is printed again, pinned to the server's current release. Re-run it and commit the file only when the pin changed: see [Updating Katap](updating.md).

**Replacing a deploy key** (it leaked, or the server lost it):
1. Delete the `KATAP_SSH_KEY` secret from that repository's environment in GitHub (**Settings → Environments → production → Environment secrets**).
2. Run `connect.sh` again. It makes, authorises and stores a new key.
3. **Revoke the old key on the server.** It stays authorised until you remove its line. Each line ends with the comment `katap <project>/<component> <environment>`. The new key is the last line with that comment.
   ```bash
   sudo -u deploy ssh-keygen -lf /home/deploy/.ssh/authorized_keys   # fingerprint and comment of each key
   sudo -u deploy nano /home/deploy/.ssh/authorized_keys             # delete the old line
   ```

**After the server's address changes:**
1. Update `host` in `/srv/katap.json` and the DNS records.
2. Trust the host key under the new address, checking its fingerprint as in [Server access](server-access.md#3-verify-the-servers-host-key).
3. Run `connect.sh` with the new address. It updates `KATAP_HOST` and `KATAP_KNOWN_HOSTS` everywhere.

**After the server is rebuilt** (a new host key, and an empty `authorized_keys`):
1. Verify the new fingerprint in the console.
2. Remove the old entry with `ssh-keygen -R 203.0.113.10`, and trust the new one.
3. **Delete every `KATAP_SSH_KEY` secret**, because the new server doesn't know those keys.
4. Run `connect.sh`.

Never skip host-key verification to get past a changed key.

A repository deploys one component per environment, so `katap.json` never lists
one repository twice for one environment.

## 3. Finish in GitHub

In each repository:

**What `connect.sh` creates in GitHub:**
- the `production` or `staging` environment, with **Deployment branches and tags** set to **Selected branches and tags**: `main` for production, `main` and `staging` for staging;
- the environment's secrets and variables;
- the repository variable `PUBLISH_ENABLED`.

It never sets reviewers. An environment that already exists must have exactly
those branch rules, as branch rules (not tag rules). Otherwise connect refuses,
because another branch could read the key. **No restriction** and **Protected
branches only** are refused too.

**What you set up**, in each repository:

1. **Commit `.github/workflows/deploy.yml`** with the command `connect.sh` printed, on `main`.
2. **Decide who approves production.** In **Settings → Environments → production → Deployment protection rules**:
   - **Required reviewers:** up to six people or teams; one approval releases the job. Until then, the job can't read the environment's secrets, including the deploy key.
   - **Prevent self-reviews:** whoever started the deployment can't approve it, even if they're a reviewer. It needs **a second eligible reviewer**. A solo maintainer who turns it on can never approve their own deploys.
   - **Plans:** on GitHub Free, Pro and Team, required reviewers work only in public repositories.

   | If you are | Choose | What it protects |
   |---|---|---|
   | A team | Reviewers plus Prevent self-reviews | No one deploys production alone |
   | A solo maintainer | Yourself as reviewer, self-review allowed | Deploys need a deliberate approval, so a stray run or someone else with write access can't deploy. It doesn't protect against your own compromised account |
   | Without reviewers (plan limit) | Branch limit only | Anyone with write access who can run the workflow on `main` can deploy any attested `main` build |

3. **Protect `main`** with a ruleset: require a pull request, block force pushes, no bypass. Anyone who can change `deploy.yml` on `main` can use the key.

**Deploying**, once `deploy.yml` is on `main` (the default branch, where GitHub looks for manually run workflows and `workflow_run` triggers):

- **Production:** **Actions** tab → **Deploy** in the workflow list → **Run workflow**.
  - **Use workflow from:** `main`. The environment only allows `main`.
  - **Where to deploy:** `production`.
  - **The image tag to deploy:** `main` (the latest build), or `sha-<the full 40-character commit>` for a specific build.

  A reviewer then approves it, if you set reviewers.
- **Staging:** deploys by itself after each successful publish from the `staging` branch. The `workflow_run` trigger in `deploy.yml` must list your publish workflow's exact `name:`.

### First deploy only

- **laravel-api:** create the Passport personal access client, which sign-in needs:
  ```bash
  sudo -iu deploy /srv/katap/bin/katap run shop api-artisan passport:client --personal --name='API Personal Access Client' --provider=users --no-interaction
  ```
  Never run `db:seed` or `UserSeeder` in production: it creates test users with a published password.
- **nestjs-api:** for a component named `api`, `katap run shop api-migrate yarn prisma:seed` creates the admin from `SEED_ADMIN_*`.

## The server's provenance token

`KATAP_GH_TOKEN` lets the server read GitHub's build attestations and verify where
an application image came from. Before a component with `"provenance": "attested"`
(the default) deploys, `bin/katap` runs:

```text
gh attestation verify oci://<image>@<digest> --repo <repo>
   --signer-workflow <repo>/.github/workflows/publish-image.yml --source-ref refs/heads/main …
```

It's a read-only verification credential:
- it doesn't authorise any SSH deploy: deploy keys do that;
- it doesn't publish or pull images.

| Not this token | What that is |
|---|---|
| Your administrator SSH key | Logs you in to the server |
| A repository's deploy key (`KATAP_SSH_KEY`) | Lets that repository's workflow ask the server to deploy one component |
| Your laptop's `gh` login | Used by `connect.sh` to create environments and secrets |
| The registry login for private images | Lets the server pull images; see [Private repositories](#private-repositories) |

**When it's needed.** Only for components that verify provenance:
- The installer lets you skip it (press Enter).
- A deploy is refused with `set KATAP_GH_TOKEN` only when it reaches a component with `"provenance": "attested"`.
- If every component sets `"provenance": "none"`, deploys don't use it. That setting removes the check entirely; see [Private repositories](#private-repositories).

### Create the token

Sign in to GitHub as a user who can read the application repositories, then open
**Settings → Developer settings → Personal access tokens → Fine-grained tokens →
Generate new token** ([direct link](https://github.com/settings/personal-access-tokens/new)).
Fill in the form:

1. **Token name:** for example `katap-provenance-read`. It's only a label.
2. **Expiration:** pick a date you'll act on. When the token expires, GitHub revokes it, and deploys of attested components are refused until you install a new one; running sites keep serving. An organization can cap token lifetimes (366 days by default for fine-grained tokens), and tokens beyond the cap are rejected for that organization's resources. Set a reminder to [rotate](#rotate-or-replace-the-token) it before then.
3. **Description:** for example `Allows Katap to read build attestations and verify application image provenance.`
4. **Resource owner:** the user or organization that owns the application repositories, such as `your-org` for `your-org/shop-api`. A fine-grained token reaches only one owner's resources. If the organization requires approval, enter a justification; see [Organization approval](#organization-approval-and-policies).
5. **Repository access** and **Permissions:** see [Repository access and permissions](#repository-access-and-permissions).
6. Select **Generate token**.

GitHub shows the token once. Copy it into a password manager, or straight into the
installer prompt. Never put it in git, chat, screenshots, logs or a command line.

### Repository access and permissions

**What's documented.** With `--repo`, `gh attestation verify` fetches attestations
from GitHub's REST API (`GET /repos/{owner}/{repo}/attestations/{digest}`). For a
fine-grained token, GitHub's documentation for that endpoint requires the
**`attestations:read`** permission, plus read access to the repository.

**The recommended setting**, for public and private repositories alike:
- **Repository access: Only select repositories.** Select every repository whose images this server verifies, which is each `repo` in `/srv/katap.json` with `"provenance": "attested"`. For example: `your-org/shop-api` and `your-org/shop-web`.
- **Permissions → Repository permissions → Attestations: Read-only.** GitHub adds the mandatory **Metadata: Read-only** on its own. Add nothing else.

**Not established:**
- **Public repositories without that permission.** GitHub says every fine-grained token can read all public repositories, and that some endpoints work on public resources without a permission, but it doesn't say whether this endpoint is one of them. Katap's installer prompt suggests the **Public repositories** access setting, but this documentation hasn't verified that it's enough. Testing it needs a real GitHub account and token. Use the recommended setting unless you've tested the other on your own repositories.
- **Repositories under another owner.** A token can select repositories of its own resource owner only. Whether a public repository under a different owner can be verified needs the same test.

**Private repositories also need:**
- **A plan that offers attestations.** Artifact attestations in private or internal repositories need **GitHub Enterprise Cloud**. On Free, Pro and Team they work in public repositories only. A token can't turn on a feature the plan lacks: the publish workflow can't create attestations, so there's nothing to verify. The publish workflow attests a private repository only when the repository variable `ATTEST_PROVENANCE=true` is set.
- **One owner per server.** Each token covers one owner, and the server holds one `KATAP_GH_TOKEN`, so one server can verify private repositories from only one owner.
- **No attestations?** Use the `"provenance": "none"` fallback, and accept what it removes; see [Private repositories](#private-repositories).

### Organization approval and policies

- If the organization requires approval for fine-grained tokens (the default), the token stays **pending** until an organization owner approves it. A pending token can read only public resources, so it can't verify private repositories. Tokens created by organization owners are approved automatically.
- An organization can block fine-grained tokens entirely, or cap their lifetime; ask an organization owner.

### Install the token

**At install time** (*server SSH session*): the installer asks once, with input hidden:

```text
GitHub token (github_pat_…, input hidden; Enter to skip):
```

Paste the token and press Enter. The installer checks that it looks like a
fine-grained token (`github_pat_…`) and writes it to `/etc/katap/katap.env`. It
doesn't ask again while that file holds a token.

**After installation, or to change it** (*server SSH session*):

```bash
sudo nano /etc/katap/katap.env
```

Set one line, without quotes or spaces, and keep the comments as they are:

```text
KATAP_GH_TOKEN=<paste the token here>
```

Then check the file is still owned by root, readable by the deploy user and by no
one else (the installer restores this on every run):

```bash
sudo stat -c '%U:%G %a' /etc/katap/katap.env      # expect root:deploy 640
```

If it doesn't print `root:deploy 640`, fix it:

```bash
sudo chown root:deploy /etc/katap/katap.env && sudo chmod 0640 /etc/katap/katap.env
```

Nothing needs restarting: `bin/katap` reads the file each time it runs.

**Check it without deploying** (*server SSH session*). This runs the same
verification for an image that's already published. It reads the token inside the
shell, so the token never appears in a command line:

```bash
sudo -u deploy bash -c 'GH_TOKEN="$(sed -n "s/^KATAP_GH_TOKEN=//p" /etc/katap/katap.env | tail -n 1)" \
  gh attestation verify oci://ghcr.io/your-org/shop-api:main --repo your-org/shop-api \
  --signer-workflow your-org/shop-api/.github/workflows/publish-image.yml --source-ref refs/heads/main >/dev/null && echo verified'
```

For a private image, log the deploy user in to the registry first (see
[Private repositories](#private-repositories)).

### Rotate or replace the token

1. Create a new token with the same settings.
2. Replace the `KATAP_GH_TOKEN=` line as above, check the file's owner and mode, and run the check.
3. Delete the old token in GitHub's token list.

GitHub can't restore an expired or revoked token, so expiry always means a new one.
Running the installer again won't ask for a token while the file still holds one,
even an expired one. Edit the file.

### When verification fails

A refused verification reads `could not verify that <image> was built by <repo>'s
publish workflow … gh said: …`. The `gh said:` part names the cause:

| Cause | What to check |
|---|---|
| Token expired or revoked (HTTP 401) | Create and install a new token |
| Wrong **Resource owner** | The token's owner must own the repository (`your-org`, not your personal account) |
| Repository not selected, or **Attestations** permission missing | The token's repository list and permissions |
| Token **pending** organization approval | Ask an organization owner to approve it |
| No attestation exists | The repository is private on a plan without attestations, `ATTEST_PROVENANCE` isn't set, the image wasn't built by `publish-image.yml`, or not from an allowed branch. Check the publish run |
| The registry refused access | The image is private and the deploy user isn't logged in to the registry |
| `GitHub did not answer … within 60s` | Network or GitHub availability; retry |

**A failed provenance check and a failed registry login are different problems:**

- **Provenance check:** `gh` couldn't establish where the image came from. Fix it through `KATAP_GH_TOKEN` and the repository's attestations.
- **Registry login:** fix it through `sudo -u deploy docker login`. It surfaces in two places:
  - for a private image, before any pull, because `gh attestation verify oci://…` must read the image from the registry with the deploy user's registry login, and fails if it can't;
  - later, as `could not pull <image>`, for a component with `"provenance": "none"`.

## Private repositories

The deploy setup relies on environment secrets and deployment branch limits. In a
private repository, those need GitHub Pro, Team or Enterprise: on GitHub Free,
environment secrets exist only in public repositories.

Attestations in a private repository need GitHub Enterprise Cloud. Set the
repository variable `ATTEST_PROVENANCE=true`, which the publish workflow reads, and
give the server's token access to the repository: see
[Repository access and permissions](#repository-access-and-permissions).

Without attestations, set `"provenance": "none"` for that component in
`/srv/katap.json`, then run `katap apply`. The server then skips the provenance
check for that component: it deploys anything pushed to that image repository,
whoever pushed it, and logs a warning on every deploy. The deploy key's limits
still apply.

### Private images

A GHCR package has its own visibility, separate from its repository's. A new
package is **private** even in a public repository. The server reads the image
twice:
- once while verifying provenance (`gh attestation verify oci://…`);
- once while pulling.

Both need registry access. So either make the package public, or log the server's
`deploy` user in to the registry. The token for that login is separate from
`KATAP_GH_TOKEN`.

**The credential.** GHCR accepts only a **personal access token (classic)**. Give
it the **`read:packages`** scope alone. Create it at **Settings → Developer settings
→ Personal access tokens → Tokens (classic)**, with an expiration.
- **Account:** the token's GitHub account must be able to read the package. A package published by a repository's workflow inherits that repository's access by default (the **Inherit access from repository** setting). Otherwise, grant the account **Read** under the package's **Manage access**.
- **SSO:** if the organization uses single sign-on, authorise the token for it (**Configure SSO** next to the token).

**Log in as `deploy`.** *Where: server SSH session.* Docker stores the login in the
home directory of the user who runs `docker login`, and Katap runs as `deploy`. So
log in as `deploy`, not as root or your administrator:

```bash
sudo -iu deploy
read -rs -p 'GHCR token: ' GHCR_TOKEN; echo
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u your-github-user --password-stdin
unset GHCR_TOKEN
```

`read -s` doesn't echo what you paste, and `printf` is a shell builtin, so the
token appears in no command line, process list or history. Piping into
`--password-stdin` alone doesn't stop a terminal from echoing what you type.

**Success:** `Login Succeeded`. Docker may warn that the credential is stored
unencrypted in `/home/deploy/.docker/config.json`. Anyone who can act as `deploy`
or root can read it, which is why the token should only read packages.

**Check it without deploying:**

```bash
docker buildx imagetools inspect ghcr.io/your-org/shop-api:main
```

It reads the image's manifest and changes nothing. `unauthorized` or `denied`
means the token, its scope, SSO or package access is wrong. `not found` usually
means the name or tag is wrong.

**Expiry and replacement:** when the token expires, verification and pulls of
private images fail. Run the same login again with a new token, which replaces the
stored one, then delete the old token in GitHub. `docker logout ghcr.io`, as
`deploy`, removes the login.

**Telling it apart from a provenance failure:** both show up as `could not verify
that … gh said: …`, because verification reads the image first. A registry problem
mentions the registry: `unauthorized`, `denied`, or a manifest that can't be read.
A provenance problem mentions attestations or the token: see
[When verification fails](#when-verification-fails). The check above separates
them. For a component with `"provenance": "none"`, a registry problem shows as
`could not pull …` instead.

The deploy workflow resolves the image tag with its own built-in token
(`packages: read`), so the workflow itself needs no extra secret.

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
