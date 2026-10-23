# Running on Google Cloud

Katap needs nothing specific to Google Cloud. This page covers where a Compute
Engine VM differs from a plain VPS. Follow the [Quick start](../README.md#quick-start)
for everything else. Google's own documentation is authoritative for the console and
`gcloud` steps; it's linked rather than repeated here.

## The VM

- **Image:** Ubuntu 24.04 LTS or Debian 12, x86-64, unless you publish multi-architecture images.
- **External address:** reserve a **static** external IPv4 address. An ephemeral one can change when the VM stops. The address is in `/srv/katap.json`, your DNS records and every repository's `KATAP_HOST` and `KATAP_KNOWN_HOSTS`.

## Firewall rules

Google Cloud's VPC firewall rules apply before traffic reaches the VM. They're
separate from the `ufw` firewall Katap turns on inside it, and Katap never changes
them. Both have to allow a port.

| Port | Needed by | Source |
|---|---|---|
| 22/tcp | You, and GitHub Actions for every deploy | Your address, plus GitHub-hosted runners (a wide, changing set of addresses) |
| 80/tcp, 443/tcp | Visitors and Let's Encrypt | Anywhere |
| 443/udp | HTTP/3 (optional) | Anywhere |

The `default` network comes with a rule that allows SSH from `0.0.0.0/0`. Ports 80
and 443 need a rule of their own. See
[VPC firewall rules](https://docs.cloud.google.com/firewall/docs/firewalls).

## IAP and the deploy Action

The deploy Action connects with plain SSH to `KATAP_HOST` on port 22. It doesn't
open an [IAP TCP forwarding](https://docs.cloud.google.com/iap/docs/using-tcp-forwarding)
tunnel, and it has no port or proxy setting.

If you restrict port 22 to IAP's range (`35.235.240.0/20`), you can still administer
the VM through `gcloud compute ssh --tunnel-through-iap`, but **deploys from
GitHub-hosted runners will fail**. Deploying through IAP would need changes to the
Action or your own workflow. Katap doesn't provide or test that.

## SSH access

Keep two kinds of keys apart:

- **Your administrator key**: a metadata SSH key, or OS Login. Use it to install, apply and run `connect.sh`.
- **Katap's deploy keys**: local to the VM, in `~deploy/.ssh/authorized_keys`, each restricted to one component.

Never put your administrator private key, or any key added through metadata or OS
Login, into a GitHub secret. See [The SSH keys involved](../README.md#the-ssh-keys-involved).

### Metadata SSH keys

With OS Login off, the guest environment creates the local account named in a
metadata key and installs that key for it. To use such an account with Katap:

- Check that it has passwordless sudo: `ssh <user>@<address> sudo -n true`.
- Don't add a metadata key for the username `deploy`. Google notes that keys written directly to `authorized_keys` may be overwritten by the guest agent for accounts it manages, and Katap's deploy keys live in `deploy`'s `authorized_keys`.

### OS Login

OS Login and Katap can coexist. Google documents that a local account can keep
using its own `authorized_keys` file while OS Login is on, as long as its username
and UID differ from the OS Login accounts. The `deploy` user is such a local
account, so deploys keep working. With OS Login on, metadata SSH keys are ignored.
See [About OS Login](https://docs.cloud.google.com/compute/docs/oslogin).

Two parts of Katap have limits under OS Login. Both come from how Katap's scripts
behave:

- **`install.sh --harden-ssh`** refuses unless an `authorized_keys` *file* exists for the sudo user or for root. OS Login supplies keys without such a file, so with an OS Login account the check refuses unless root has one. Hardening also turns off keyboard-interactive login, which two-step verification prompts may rely on (**unverified**: test it before relying on it). Skip `--harden-ssh` and use OS Login's own controls instead.
- **`connect.sh`** runs `ssh` with `BatchMode=yes` and `sudo -n`. It can't answer an OS Login two-step verification prompt or a sudo password. With OS Login 2FA on, run `connect.sh` as a local administrator account with a key and passwordless sudo, or follow [Doing it by hand](connecting-apps.md#doing-it-by-hand).

Your OS Login account needs `roles/compute.osAdminLogin` for sudo. Check that sudo
doesn't ask for a password with `sudo -n true`.

## Service accounts and scopes

Katap calls no Google Cloud API, so the VM needs no service account permissions for
Katap itself.

On Compute Engine, a VM's **access scopes** only set a ceiling. The attached service
account's **IAM roles** grant the actual permissions, and both must allow an
action (see
[Service accounts](https://docs.cloud.google.com/compute/docs/access/service-accounts)).
So choosing "Allow full access to all Cloud APIs":

- grants no IAM permission;
- gives the server no GitHub access: it still needs `KATAP_GH_TOKEN`, and a registry login for private images;
- gives GitHub Actions no access to the VM: deploys still use the deploy keys from `connect.sh`.

## Backups to Cloud Storage

A Cloud Storage bucket receives Katap's dumps only after you connect it to rclone,
as [What a backup covers](operations.md#what-a-backup-covers) describes:

1. Install rclone.
2. Configure a remote for the `deploy` user with credentials that can write to the bucket: the VM's service account (with a storage role on the bucket, and a scope that allows Cloud Storage) or a key of your own. See [rclone's Google Cloud Storage docs](https://rclone.org/googlecloudstorage/).
3. Wrap it in a `crypt` remote.
4. Set `KATAP_RCLONE_REMOTE`.

Creating the bucket alone connects nothing.
