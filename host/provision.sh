#!/usr/bin/env bash
#
# Prepares an Ubuntu/Debian host to run Katap. Idempotent: safe to run again, and
# it never touches project data, secrets or running containers.
#
#   sudo /srv/katap/host/provision.sh [--ci-key '<ssh public key>' --ci-env production|staging] [--harden-ssh]
#
# Katap must already be cloned at /srv/katap (the systemd units and the forced SSH
# command name that path).
#
#   --ci-key      authorise a CI deploy key for the deploy user, restricted to
#                 `katap ssh-dispatch <environment>` (deploy and rollback only, validated
#                 arguments, components of that environment only). One key per
#                 environment: run once with --ci-env production, once with staging.
#   --ci-env      the environment that key serves (required with --ci-key)
#   --harden-ssh  password and keyboard-interactive login off, root by key only.
#                 Refused unless an authorised key already exists for root or the
#                 user running sudo, so it cannot lock you out.
#
# Environment: KATAP_DEPLOY_USER (deploy), KATAP_SWAP_SIZE (2G; 0 skips).
set -euo pipefail

KATAP_ROOT=/srv/katap
DEPLOY_USER="${KATAP_DEPLOY_USER:-deploy}"
SWAP_SIZE="${KATAP_SWAP_SIZE:-2G}"

log() { echo "provision: $*"; }
die() { echo "provision: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
[ -x "$KATAP_ROOT/bin/katap" ] || die "clone Katap to $KATAP_ROOT first."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "supported on Ubuntu and Debian only (this is '${ID:-unknown}')." ;;
esac

ci_key=''
ci_env=''
harden_ssh=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ci-key) ci_key="${2:-}"; shift 2 ;;
        --ci-env) ci_env="${2:-}"; shift 2 ;;
        --harden-ssh) harden_ssh=true; shift ;;
        *) die "unknown option '$1'." ;;
    esac
done

# --- Packages -------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg jq openssl util-linux git ufw unattended-upgrades

if ! command -v docker >/dev/null; then
    log "installing Docker Engine from Docker's repository."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Security updates install themselves. Docker's own packages update too; a
# dockerd upgrade restarts containers, which `restart: unless-stopped` brings back.
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- Docker daemon: bounded logs ------------------------------------------------
# Every katap service sets its own json-file limits; this is the default for anything
# else. An existing daemon.json is never rewritten.
if [ ! -f /etc/docker/daemon.json ]; then
    log "writing /etc/docker/daemon.json (log rotation, live-restore)."
    cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
JSON
    systemctl restart docker
elif ! jq -e '."log-opts"."max-size"' /etc/docker/daemon.json >/dev/null; then
    log "WARNING: /etc/docker/daemon.json sets no log-opts max-size; container logs can fill the disk."
fi
systemctl enable --now docker

# The base Laravel image's entrypoint relies on this (it is the kernel default).
sysctl -q -w fs.protected_hardlinks=1
echo 'fs.protected_hardlinks = 1' > /etc/sysctl.d/60-katap.conf

# --- Swap -----------------------------------------------------------------------
# A small VPS without swap meets a memory spike with the OOM killer, which may pick
# a database.
if [ "$SWAP_SIZE" != 0 ] && [ -z "$(swapon --show --noheadings)" ]; then
    log "creating a $SWAP_SIZE swap file."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Firewall -------------------------------------------------------------------
# Defence in depth only: ports Docker publishes bypass ufw, which is why Katap's
# contract allows the edge alone to publish any.
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null

# --- Deploy user and host layout ------------------------------------------------
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    log "creating user '$DEPLOY_USER'."
    useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
# Membership of the docker group is root-equivalent on this host. The CI key is
# limited by its forced command; anyone with the user's password or another key
# is not.
usermod -aG docker "$DEPLOY_USER"

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0755 /srv/state /srv/edge /srv/edge/certs
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0700 /srv/secrets /srv/backups
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$KATAP_ROOT"

if [ -n "$ci_key" ]; then
    case "$ci_env" in
        production|staging) ;;
        *) die "--ci-key needs --ci-env production|staging." ;;
    esac
    # One line, one key: a pasted value carrying a newline would add a second,
    # unrestricted authorized_keys entry.
    [[ "$ci_key" != *$'\n'* && "$ci_key" != *$'\r'* ]] || die "--ci-key must be a single line."
    [[ "$ci_key" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\ [A-Za-z0-9+/=]+(\ [[:print:]]*)?$ ]] || die "--ci-key is not an SSH public key."
    home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
    install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0700 "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    key_body="$(cut -d' ' -f1-2 <<<"$ci_key")"
    # Already present without the forced command (installed by hand): never leave
    # the CI key with a full shell.
    existing="$(grep -F "$key_body" "$home/.ssh/authorized_keys" || true)"
    if [ -n "$existing" ] && ! grep -qxF "restrict,command=\"$KATAP_ROOT/bin/katap ssh-dispatch $ci_env\" $ci_key" <<<"$existing"; then
        die "the CI key is already in $home/.ssh/authorized_keys with another restriction or none; remove that line and run again."
    fi
    if ! grep -qF "$key_body" "$home/.ssh/authorized_keys"; then
        echo "restrict,command=\"$KATAP_ROOT/bin/katap ssh-dispatch $ci_env\" $ci_key" >> "$home/.ssh/authorized_keys"
        log "authorised the $ci_env CI key for '$DEPLOY_USER' (deploy and rollback of $ci_env components only)."
    fi
    chown "$DEPLOY_USER:$DEPLOY_USER" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
fi

# --- SSH hardening (opt-in) -----------------------------------------------------
if [ "$harden_ssh" = true ]; then
    admin="${SUDO_USER:-root}"
    admin_home="$(getent passwd "$admin" | cut -d: -f6)"
    [ -s "$admin_home/.ssh/authorized_keys" ] || [ -s /root/.ssh/authorized_keys ] \
        || die "--harden-ssh refused: no authorised key for '$admin' or root, so key login is not proven to work."
    cat > /etc/ssh/sshd_config.d/10-katap.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
    sshd -t || { rm -f /etc/ssh/sshd_config.d/10-katap.conf; die "sshd rejected the hardening; nothing was changed."; }
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    log "SSH: passwords off, root by key only."
fi

# --- Timers ---------------------------------------------------------------------
install -m 0644 "$KATAP_ROOT"/host/systemd/katap-*.service "$KATAP_ROOT"/host/systemd/katap-*.timer /etc/systemd/system/
sed -i "s/^User=.*/User=$DEPLOY_USER/" /etc/systemd/system/katap-cron.service /etc/systemd/system/katap-backup.service
systemctl daemon-reload
systemctl enable --now katap-cron.timer katap-backup.timer

# --- The edge -------------------------------------------------------------------
sudo -u "$DEPLOY_USER" "$KATAP_ROOT/bin/katap" edge up

log "done. Next: log the deploy user in to your registry if images are private:"
log "  sudo -u $DEPLOY_USER docker login ghcr.io -u <user> --password-stdin   (a read:packages token)"
