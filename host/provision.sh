#!/usr/bin/env bash
#
# Prepares an Ubuntu/Debian host to run Katap. Idempotent: safe to run again, and
# it never touches project data, secrets or running containers. install.sh runs it
# after checking out a release; run it by hand only from a checkout at /srv/katap.
#
#   sudo /srv/katap/host/provision.sh [--harden-ssh]
#
# Katap must already be at /srv/katap (the systemd units, the `katap` command and
# every deploy key's forced command name that path).
#
#   --harden-ssh    password and keyboard-interactive login off, root by key only.
#                   Refused unless an authorised key already exists for root or the
#                   user running sudo, so it cannot lock you out.
#
# Environment: KATAP_DEPLOY_USER (deploy), KATAP_SWAP_SIZE (2G; 0 skips).
set -euo pipefail

KATAP_ROOT=/srv/katap
DEPLOY_USER="${KATAP_DEPLOY_USER:-deploy}"
SWAP_SIZE="${KATAP_SWAP_SIZE:-2G}"

log() { echo "provision: $*"; }
die() { echo "provision: $*" >&2; exit 1; }

# Writes this host's edge settings once, from the tool's defaults, so a later
# release that changes a default never moves this host's edge: CADDY_IP and the
# TLS mode are baked into secrets already generated. Never overwritten.
pin_edge_settings() {
    local defaults="$1" dest="$2"
    [ ! -f "$dest" ] || return 0
    {
        echo "# This host's edge settings; they override $defaults key by key."
        echo "# Written once by host/provision.sh from the defaults of the Katap release it ran."
        echo "# Change a value here, then run: katap edge up"
        grep -E '^[A-Z_]+=' "$defaults"
    } > "$dest"
}

# Writes /srv/katap.json once: the projects `katap apply` creates. Root-owned and
# read by the deploy user, so nothing it runs can change what this host deploys.
write_projects_file() {
    local file="$1"
    [ ! -e "$file" ] || return 0
    printf '%s\n' '{' '  "host": "",' '  "projects": {}' '}' > "$file"
    chown root:root "$file"
    chmod 0644 "$file"
}

# The `katap` command an administrator types: it runs the tool as the deploy user,
# who owns every project, so nobody types `sudo -u deploy /srv/katap/bin/katap`.
write_katap_command() {
    local file="$1"
    cat > "$file.tmp" <<EOF
#!/bin/sh
# Runs Katap as the user that owns its projects. Written by host/provision.sh.
if [ "\$(id -un)" = '$DEPLOY_USER' ]; then
    exec $KATAP_ROOT/bin/katap "\$@"
fi
exec sudo -u '$DEPLOY_USER' -H -- $KATAP_ROOT/bin/katap "\$@"
EOF
    chown root:root "$file.tmp"
    chmod 0755 "$file.tmp"
    mv "$file.tmp" "$file"
}

main() {
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
[ -x "$KATAP_ROOT/bin/katap" ] || die "install Katap at $KATAP_ROOT first (see install.sh)."

harden_ssh=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --harden-ssh) harden_ssh=true; shift ;;
        *) die "unknown option '$1'." ;;
    esac
done

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "supported on Ubuntu and Debian only (this is '${ID:-unknown}')." ;;
esac

# --- Packages -------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg jq openssl util-linux git ufw unattended-upgrades nano

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
# Membership of the docker group is root-equivalent on this host. Deploy keys are
# limited by their forced command; anyone with the user's password or another key
# is not.
usermod -aG docker "$DEPLOY_USER"
deploy_home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0700 "$deploy_home/.ssh"

# Everything about this host's projects lives under /srv, outside the tool, so a
# release of Katap replaces the tool and nothing else.
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0755 /srv/state /srv/edge /srv/edge/certs /srv/projects
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0700 /srv/secrets /srv/backups
# The tool is root's and only readable by the deploy user: install.sh runs git in
# it as root, which must never pick up hooks or config another user wrote, and the
# deploy keys' forced command runs it.
chown -R root:root "$KATAP_ROOT"
# Readable whatever root's umask was when install.sh cloned it.
chmod -R u+rwX,go+rX,go-w "$KATAP_ROOT"
write_projects_file /srv/katap.json
pin_edge_settings "$KATAP_ROOT/edge/edge.env" /srv/edge/edge.env
chown "$DEPLOY_USER:$DEPLOY_USER" /srv/edge/edge.env
write_katap_command /usr/local/bin/katap

# Host settings, read by bin/katap itself. Never overwritten.
install -d -m 0755 /etc/katap
if [ ! -f /etc/katap/katap.env ]; then
    cat > /etc/katap/katap.env <<'ENV'
# Katap host settings. Read as data by bin/katap, its only reader; one KEY=value
# per line, the last line for a key wins. Every setting is optional.
#
# An rclone remote for off-host copies of every database dump.
# KATAP_RCLONE_REMOTE=b2:my-bucket/katap
#
# Dumps kept per component and kind (default 14).
# KATAP_BACKUP_KEEP=14
#
# Earlier releases kept per component for rollback (default 5).
# KATAP_RELEASES_KEPT=5
#
# Seconds a deploy key waits after its last dispatch before it may
# dispatch again (default 60).
# KATAP_DISPATCH_COOLDOWN=60
ENV
fi
chown "root:$DEPLOY_USER" /etc/katap/katap.env
chmod 0640 /etc/katap/katap.env

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
# Named, never globbed: a file that is not part of the release never becomes a unit.
units=(katap-cron.service katap-cron.timer katap-backup.service katap-backup.timer)
install -m 0644 "${units[@]/#/$KATAP_ROOT/host/systemd/}" /etc/systemd/system/
sed -i "s/^User=.*/User=$DEPLOY_USER/" /etc/systemd/system/katap-cron.service /etc/systemd/system/katap-backup.service
systemctl daemon-reload
systemctl enable --now katap-cron.timer katap-backup.timer

# --- The edge -------------------------------------------------------------------
sudo -u "$DEPLOY_USER" "$KATAP_ROOT/bin/katap" edge up

log "done. Next:"
if jq -e '(.projects // {}) | length > 0' /srv/katap.json >/dev/null 2>&1; then
    log "  - after any change to /srv/katap.json: katap apply"
else
    log "  - describe your projects in /srv/katap.json (sudo nano /srv/katap.json), then: katap apply"
fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
