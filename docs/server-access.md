# Server access and identity

What you need to install and run Katap:
- an administrator login by SSH key;
- `sudo` on that account (or `root`);
- the server's host key, checked before you trust it.

GitHub Actions needs none of this: its key and the server's host key come from
`katap deploy-key`, which reads them on the server itself.

Examples use `admin` and `203.0.113.10`; replace them with your own.

## The three kinds of SSH key

| Key | Lives | Used for |
|---|---|---|
| **Your administrator key** | Your computer only | Logging in to install Katap and run `katap`. Full control of the server |
| **Deploy keys** | GitHub, one per component (`KATAP_SSH_KEY`) | Made by `katap deploy-key`. Each one can only deploy or roll back one component |
| **The server's host key** | The server (`/etc/ssh/ssh_host_ed25519_key`); its public half is in your `known_hosts` and in each repository's `KATAP_KNOWN_HOSTS` | Proving that you, and GitHub Actions, are talking to your server |

Never put your administrator private key in GitHub.

## 1. An administrator login

*Where: your provider's console, or an existing SSH session.*

Most providers give you `root` with your SSH key, which works as it is. A non-root
administrator needs your public key in its `~/.ssh/authorized_keys` and `sudo`;
on Ubuntu and Debian, the `sudo` group gives it. `katap` uses `sudo` to run as
the deploy user, and asks for the password when the account has one.

## 2. A non-default key: `~/.ssh/config`

*Where: your computer.* Name the server once:

```text
Host katap-prod
    HostName 203.0.113.10
    User admin
    IdentityFile ~/.ssh/katap_admin_ed25519
    IdentitiesOnly yes
```

Then `ssh katap-prod` logs in with that key. Leave `Port` unset: deploys from
GitHub always use port 22.

## 3. Verify the server's host key

The first time you connect, SSH shows a fingerprint and asks whether to trust it.
Compare it with one you got from a trusted source, never just from the network.
`ssh-keyscan` alone proves nothing: it asks the same network you're trying to
verify.

**Get the real fingerprint.** *Where: your provider's web or serial console, or
another channel already authenticated to the server.*

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

```text
256 SHA256:Xy7…(43 characters)… root@server (ED25519)
```

Some images also print the host key fingerprints to the console log during their
first boot.

**Compare it on first connect.** *Where: your computer.*

```bash
ssh -o HostKeyAlgorithms=ssh-ed25519 admin@203.0.113.10 true
```

```text
ED25519 key fingerprint is SHA256:Xy7…
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Type `yes` only if the whole `SHA256:…` string matches what the console showed.
Otherwise type `no` and find out why.

## Common failures

| Symptom | Cause |
|---|---|
| `Permission denied (publickey)` | The wrong key, user or alias; check `ssh -v` |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` | The server was rebuilt, the address now points at another machine, or something is intercepting. Verify the new fingerprint in the console before removing the old entry with `ssh-keygen -R 203.0.113.10`. A rebuilt server also needs new deploy keys: see [Replacing a deploy key](deploying.md#replacing-a-deploy-key) |
| `sudo: … is not in the sudoers file` | The account has no `sudo`; see step 1 |

On Google Cloud, OS Login and its two-step verification change some of this; see
[Running on Google Cloud](gcp.md#ssh-access).
