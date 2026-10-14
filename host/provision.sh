#!/usr/bin/env bash
#
# Prepares an Ubuntu/Debian host to run Katap. Idempotent: safe to run again, and
# it never touches project data, secrets or running containers. install.sh runs it
# after checking out a release; run it by hand only from a checkout at /srv/katap.
#
#   sudo /srv/katap/host/provision.sh [--harden-ssh]
#   sudo /srv/katap/host/provision.sh --ci-key '<ssh public key>'|- --ci-env production|staging \
#        --ci-project <project> --ci-component <component>[,<component>...]
#
# Katap must already be at /srv/katap (the systemd units and the forced SSH
# command name that path). With only --ci-* options it authorises the key and
# changes nothing else; connect.sh calls it that way.
#
#   --ci-key        authorise an application's deploy key for the deploy user,
#                   restricted to `katap ssh-dispatch <environment> <project> <components>`:
#                   deploy and rollback of exactly those components, nothing else.
#                   One key per application repository and environment. `-` reads
#                   the key from standard input.
#   --ci-env        the environment that key serves
#   --ci-project    the project it may deploy
#   --ci-component  the component(s) of that project it may deploy, comma-separated
#   --harden-ssh    password and keyboard-interactive login off, root by key only.
#                 Refused unless an authorised key already exists for root or the
#                 user running sudo, so it cannot lock you out.
#
# Environment: KATAP_DEPLOY_USER (deploy), KATAP_SWAP_SIZE (2G; 0 skips),
# KATAP_GH_TOKEN (written to /etc/katap/katap.env when it holds none; otherwise
# asked for on the terminal). sudo drops the environment: pass it with
# `sudo --preserve-env=KATAP_GH_TOKEN`, never on the command line.
set -euo pipefail

KATAP_ROOT=/srv/katap
DEPLOY_USER="${KATAP_DEPLOY_USER:-deploy}"
SWAP_SIZE="${KATAP_SWAP_SIZE:-2G}"

log() { echo "provision: $*"; }
die() { echo "provision: $*" >&2; exit 1; }

# Adds one application's deploy key to <authorized_keys>, bound by its forced
# command. Every value is validated before it is written into the line: a stray
# quote or newline would leave the key with other options, or none.
authorize_ci_key() {
    local file="$1" env="$2" project="$3" components="$4" key="$5"
    case "$env" in
        production|staging) ;;
        *) die "--ci-key needs --ci-env production|staging." ;;
    esac
    [[ "$project" =~ ^[a-z][a-z0-9-]{0,29}$ ]] || die "--ci-key needs --ci-project <project> (lowercase letters, digits, hyphens)."
    [[ "$components" =~ ^[a-z][a-z0-9]{0,19}(,[a-z][a-z0-9]{0,19})*$ ]] \
        || die "--ci-key needs --ci-component <component>[,<component>...] (lowercase letters and digits)."
    # One line, one key: a pasted value carrying a newline would add a second,
    # unrestricted authorized_keys entry.
    [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] || die "--ci-key must be a single line."
    [[ "$key" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\ [A-Za-z0-9+/=]+(\ [[:print:]]*)?$ ]] || die "--ci-key is not an SSH public key."

    local line key_body existing
    line="restrict,command=\"$KATAP_ROOT/bin/katap ssh-dispatch $env $project $components\" $key"
    key_body="$(cut -d' ' -f1-2 <<<"$key")"
    touch "$file"
    # Already present with another binding, or none (installed by hand): one key
    # never serves two bindings, and never gets a full shell.
    existing="$(grep -F "$key_body" "$file" || true)"
    if [ -n "$existing" ] && ! grep -qxF "$line" <<<"$existing"; then
        die "that key is already in $file with another restriction or none; remove that line and run again."
    fi
    if [ -z "$existing" ]; then
        echo "$line" >> "$file"
        log "authorised a $env deploy key for $project/{$components}."
    fi
}

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

# The GitHub token of <file>, or nothing: the last line for the key wins, as
# bin/katap reads it.
current_gh_token() {
    local line
    line="$(grep -E '^KATAP_GH_TOKEN=' "$1" | tail -n 1 || true)"
    line="${line#*=}"
    line="${line//[[:space:]\"\']/}"
    printf '%s' "$line"
}

# Writes <token> as the one KATAP_GH_TOKEN= line of <file>, in place of the first
# and dropping any other, keeping every other line, the owner and the mode. A
# token is one word of the fine-grained format: a pasted newline would otherwise
# add settings of its own.
write_gh_token() {
    local file="$1" token="$2" tmp
    [[ "$token" =~ ^github_pat_[A-Za-z0-9_]{20,255}$ ]] \
        || die "that is not a fine-grained GitHub token (github_pat_…); create one with read-only access (see /etc/katap/katap.env)."
    tmp="$(mktemp "$(dirname "$file")/.katap.env.XXXXXX")"
    # The token reaches awk through its environment, never its command line,
    # where any local user could read it; the copy goes however this ends.
    # shellcheck disable=SC2064 # expanded now: the path of this temporary file
    trap "rm -f '$tmp'" EXIT
    KATAP_LINE="KATAP_GH_TOKEN=$token" awk '
        /^KATAP_GH_TOKEN=/ { if (!done) { print ENVIRON["KATAP_LINE"]; done = 1 }; next }
        { print }
        END { if (!done) print ENVIRON["KATAP_LINE"] }
    ' "$file" > "$tmp"
    chown --reference="$file" "$tmp"
    chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
    trap - EXIT
}

# Reads the deploy key from standard input for `--ci-key -`: one line, so the key
# never sits in a remote command line.
read_ci_key() {
    local key=''
    IFS= read -r key || [ -n "$key" ] || die "--ci-key -: no key on standard input."
    printf '%s' "$key"
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

main() {
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
[ -x "$KATAP_ROOT/bin/katap" ] || die "install Katap at $KATAP_ROOT first (see install.sh)."

ci_key=''
ci_env=''
ci_project=''
ci_components=''
harden_ssh=false
host_options=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ci-key) ci_key="${2:-}"; shift 2 ;;
        --ci-env) ci_env="${2:-}"; shift 2 ;;
        --ci-project) ci_project="${2:-}"; shift 2 ;;
        --ci-component) ci_components="${2:-}"; shift 2 ;;
        --harden-ssh) harden_ssh=true; host_options=true; shift ;;
        *) die "unknown option '$1'." ;;
    esac
done
[ "$ci_key" != - ] || ci_key="$(read_ci_key)"

# Only --ci-* options: authorise the key and change nothing else on the host.
if [ "$host_options" = false ] && [ -n "$ci_key$ci_env$ci_project$ci_components" ]; then
    id "$DEPLOY_USER" >/dev/null 2>&1 || die "no user '$DEPLOY_USER'; provision the host first."
    authorize_deploy_key
    return 0
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "supported on Ubuntu and Debian only (this is '${ID:-unknown}')." ;;
esac

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

# The host verifies each image's build provenance with the GitHub CLI before it
# deploys it.
if ! command -v gh >/dev/null; then
    log "installing the GitHub CLI from GitHub's repository."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -q
    apt-get install -y -q gh
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

# Host settings, read by bin/katap itself: holds a GitHub token, so readable by
# root and the deploy user only. Never overwritten.
install -d -m 0755 /etc/katap
if [ ! -f /etc/katap/katap.env ]; then
    cat > /etc/katap/katap.env <<'ENV'
# Katap host settings. Read as data by bin/katap, its only reader; one KEY=value
# per line, the last line for a key wins.
#
# A GitHub token the host uses to verify each image's build provenance before
# deploying it: a fine-grained token with read-only access to public repositories,
# or with "Attestations: read" on private application repositories.
KATAP_GH_TOKEN=
#
# Optional: an rclone remote for off-host copies of every database dump.
# KATAP_RCLONE_REMOTE=b2:my-bucket/katap
#
# Optional: dumps kept per component and kind (default 14).
# KATAP_BACKUP_KEEP=14
#
# Optional: seconds a deploy key waits after its last dispatch before it may
# dispatch again (default 60).
# KATAP_DISPATCH_COOLDOWN=60
#
# Optional: seconds the host waits for GitHub to answer one provenance check
# (default 60).
# KATAP_GH_TIMEOUT=60
ENV
fi
chown "root:$DEPLOY_USER" /etc/katap/katap.env
chmod 0640 /etc/katap/katap.env

# The token the host verifies images with: from KATAP_GH_TOKEN, else asked for on
# the terminal (never standard input, which is install.sh itself when piped).
if [ -z "$(current_gh_token /etc/katap/katap.env)" ]; then
    token="${KATAP_GH_TOKEN:-}"
    if [ -z "$token" ] && { : </dev/tty; } 2>/dev/null; then
        echo "A GitHub token lets this host verify that each image was built by its own repository."
        echo "Create a fine-grained token with read-only access to public repositories (or"
        echo "\"Attestations: read\" on private ones): https://github.com/settings/personal-access-tokens/new"
        read -rs -p "GitHub token (github_pat_…, input hidden; Enter to skip): " token </dev/tty || token=''
        echo
    fi
    if [ -n "$token" ]; then
        write_gh_token /etc/katap/katap.env "$token"
        log "wrote the GitHub token to /etc/katap/katap.env."
    fi
    unset token
fi

[ -z "$ci_key$ci_env$ci_project$ci_components" ] || authorize_deploy_key

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
[ -n "$(current_gh_token /etc/katap/katap.env)" ] \
    || log "  - set KATAP_GH_TOKEN in /etc/katap/katap.env (see the comments there);"
if jq -e '(.projects // {}) | length > 0' /srv/katap.json >/dev/null 2>&1; then
    log "  - after any change to /srv/katap.json: sudo -u $DEPLOY_USER $KATAP_ROOT/bin/katap apply"
else
    log "  - describe your projects in /srv/katap.json (sudo nano /srv/katap.json), then:"
    log "      sudo -u $DEPLOY_USER $KATAP_ROOT/bin/katap apply"
fi
log "  - if images are private: sudo -u $DEPLOY_USER docker login ghcr.io -u <user> --password-stdin   (a read:packages token)."
}

# The deploy user's authorized_keys gains the key from the --ci-* options.
authorize_deploy_key() {
    [ -n "$ci_key" ] || die "--ci-env, --ci-project and --ci-component go with --ci-key."
    local home
    home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
    install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0700 "$home/.ssh"
    authorize_ci_key "$home/.ssh/authorized_keys" "$ci_env" "$ci_project" "$ci_components" "$ci_key"
    chown "$DEPLOY_USER:$DEPLOY_USER" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
}

# Sourced by tests for authorize_ci_key; run as a script, it provisions the host.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
