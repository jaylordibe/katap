# Server access and identity

What you need before installing Katap and running `connect.sh`:
- an administrator login by SSH key;
- passwordless `sudo`;
- the server's host key, checked and trusted on your computer.

Examples use `admin` and `203.0.113.10`; replace them with your own.

## The three kinds of SSH key

| Key | Lives | Used for |
|---|---|---|
| **Your administrator key** | Your computer only | Logging in to install Katap, run `apply` and run `connect.sh`. Full control of the server |
| **Deploy keys** | GitHub, one per repository and environment (`KATAP_SSH_KEY`) | Created by `connect.sh`. Each one can only deploy or roll back one component |
| **The server's host key** | The server (`/etc/ssh/ssh_host_ed25519_key`); its public half is pinned in your `known_hosts` and in each repository's `KATAP_KNOWN_HOSTS` | Proving that you, and GitHub Actions, are talking to your server |

Never put your administrator private key in GitHub.

## 1. An administrator login

*Where: your provider's console, or an existing SSH session.*

Most providers give you `root` with your SSH key, which works as it is. To use a
non-root administrator instead, the account needs your public key in its
`~/.ssh/authorized_keys` and a sudo rule that doesn't ask for a password. On Ubuntu
and Debian, edit the rule with `visudo`, which checks the syntax before saving:

```bash
sudo visudo -f /etc/sudoers.d/90-katap-admin
```

```text
admin ALL=(ALL) NOPASSWD:ALL
```

Passwordless sudo makes that account as powerful as root. Protect its key
accordingly.

## 2. A non-default key: `~/.ssh/config`

*Where: your computer.*

Katap's scripts have no key option; they use your SSH configuration. Add a host
alias:

```text
Host katap-prod
    HostName 203.0.113.10
    User admin
    IdentityFile ~/.ssh/katap_admin_ed25519
    IdentitiesOnly yes
```

Then use `katap-prod` wherever the docs show `admin@203.0.113.10`, for example
`connect.sh | bash -s -- katap-prod`. Leave `Port` unset: deploys from GitHub
always use port 22.

**A key with a passphrase** must be loaded into your SSH agent, because
`connect.sh` runs `ssh` with `BatchMode=yes` and can't ask for it:

```bash
ssh-add ~/.ssh/katap_admin_ed25519      # on macOS, add --apple-use-keychain to remember it
ssh-add -l                              # lists the key's fingerprint when it's loaded
```

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

**Compare it on first connect.** *Where: your computer.* Ask for the ed25519 key
specifically, which is the one Katap pins:

```bash
ssh -o HostKeyAlgorithms=ssh-ed25519 admin@203.0.113.10 true
```

```text
ED25519 key fingerprint is SHA256:Xy7…
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Type `yes` only if the whole `SHA256:…` string matches what the console showed.
Otherwise type `no` and find out why.

**Success:** the command returns with no prompt the next time you run it.
`connect.sh` refuses to run until your `known_hosts` holds this ed25519 key for
the address you connect to.

## 4. Check passwordless sudo

*Where: your computer.*

```bash
ssh admin@203.0.113.10 sudo -n true && echo "passwordless sudo works"
```

- **Success:** it prints `passwordless sudo works`.
- **Failure:** `sudo: a password is required` means the sudo rule from step 1 is missing or wrong. A permission error before that means the key or user is wrong. As `root`, no sudo rule is needed.

## Common failures

| Symptom | Cause |
|---|---|
| `Permission denied (publickey)` | The wrong key, user or alias; check `ssh -v`, and `ssh-add -l` for a passphrase-protected key |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` | The server was rebuilt, the address now points at another machine, or something is intercepting. Verify the new fingerprint in the console before removing the old entry with `ssh-keygen -R 203.0.113.10` |
| `connect: the server's ed25519 host key is not in your known_hosts` | You trusted another key type only. Run the `ssh -o HostKeyAlgorithms=ssh-ed25519 …` command above |
| `sudo: a password is required` | No passwordless rule; see step 1 |

On Google Cloud, OS Login and its two-step verification change some of this; see
[Running on Google Cloud](gcp.md#ssh-access).
