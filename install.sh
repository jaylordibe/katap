#!/usr/bin/env bash
#
# Installs Katap on an Ubuntu or Debian server, or upgrades it in place.
#
#   curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash -s -- --version v1.2.0
#
# This script is served from main, so it does as little as possible: it finds the
# release (the latest GitHub Release, or --version), resolves its tag to a commit,
# checks the tool out at /srv/katap at exactly that commit, records it in
# /etc/katap/release, and hands over to that release's own host/provision.sh.
# Everything after the checkout is the release's code, not main's.
#
# Running it again upgrades to the latest release and keeps every project, secret
# and backup: they live under /srv, outside the tool. It refuses, changing nothing:
#   - a tool checkout with local changes (they would be lost, or run as root);
#   - a release older than this installer supports.
# Read a release's notes before moving to it, a new major version above all.
#
# Options: see usage below (`--help`). The GitHub token is asked for on the
# terminal; to answer without one, export KATAP_GH_TOKEN and pipe into
# `sudo --preserve-env=KATAP_GH_TOKEN bash` (never put the token on a command line).
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/install.sh | sudo bash -s -- [options]

  --version vX.Y.Z   install or move to this release (default: the latest GitHub Release)
  --harden-ssh       passed to provision.sh: password login off, root by key only
  -h, --help         this text
USAGE
}

# Everything is inside main, called on the last line: a download cut short runs
# nothing at all.
main() {
    local repo_url="${KATAP_REPO_URL:-https://github.com/jaylordibe/katap.git}"
    local api_url="${KATAP_API_URL:-https://api.github.com/repos/jaylordibe/katap}"
    # Test seams: where the tool and the release record go, and what runs after.
    local root="${KATAP_INSTALL_ROOT:-/srv/katap}"
    local release_file="${KATAP_RELEASE_FILE:-/etc/katap/release}"
    local provision="${KATAP_PROVISION:-$root/host/provision.sh}"
    # The first release whose provision.sh this installer knows how to call.
    local oldest=1.1.0

    die() { echo "install: $*" >&2; exit 1; }
    log() { echo "install: $*"; }

    local version='' pass=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version) [ "$#" -ge 2 ] || die "--version needs a release, e.g. --version v1.1.0."; version="$2"; shift 2 ;;
            --harden-ssh) pass+=("$1"); shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option '$1'." ;;
        esac
    done

    [ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL <url> | sudo bash"

    local need=() tool
    for tool in git curl jq; do
        command -v "$tool" >/dev/null || need+=("$tool")
    done
    if [ "${#need[@]}" -gt 0 ]; then
        command -v apt-get >/dev/null || die "install ${need[*]} first (Katap supports Ubuntu and Debian)."
        log "installing ${need[*]}."
        DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q ca-certificates "${need[@]}" >/dev/null
    fi

    # --- Which release ----------------------------------------------------------
    local tag
    if [ -n "$version" ]; then
        tag="$version"
    else
        local latest code
        latest="$(mktemp)"
        # shellcheck disable=SC2064 # expanded now: the trap outlives main's locals
        trap "rm -f '$latest'" EXIT
        code="$(curl -sSL --proto '=https,file' -o "$latest" -w '%{http_code}' "$api_url/releases/latest" 2>/dev/null)" \
            || die "could not reach GitHub ($api_url); Katap was not installed or changed."
        case "$code" in
            2*|000) tag="$(jq -r '.tag_name // empty' "$latest" 2>/dev/null || true)" ;;
            404) tag='' ;;
            403|429) die "GitHub refused the request (rate limit); try again later, or pass --version vX.Y.Z. Katap was not installed or changed." ;;
            *) die "GitHub answered HTTP $code for $api_url/releases/latest; Katap was not installed or changed." ;;
        esac
        rm -f "$latest"
        trap - EXIT
        [ -n "$tag" ] || die "no published release of Katap found ($api_url/releases/latest); pass --version vX.Y.Z of a release at or after v$oldest. Katap was not installed or changed."
    fi
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$tag' is not a release (expected vX.Y.Z)."
    version_at_least "${tag#v}" "$oldest" || die "$tag is older than this installer supports ($oldest); install it by hand as its own README says."

    # The commit the tag names on GitHub now: an annotated tag's ^{} line, or the
    # tag itself when it is lightweight.
    local refs commit
    refs="$(git ls-remote "$repo_url" "refs/tags/$tag" "refs/tags/$tag^{}")" || die "could not reach $repo_url."
    commit="$(awk -v t="refs/tags/$tag^{}" '$2 == t { print $1 }' <<<"$refs")"
    [ -n "$commit" ] || commit="$(awk -v t="refs/tags/$tag" '$2 == t { print $1 }' <<<"$refs")"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "no release $tag in $repo_url."

    # --- The checkout -------------------------------------------------------------
    # Hooks and fsmonitor off: git as root must never run anything a checkout
    # carries. No safe.directory: a tool directory root does not own is refused,
    # never trusted.
    g() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "$root" "$@"; }
    if [ ! -e "$root/.git" ]; then
        [ ! -e "$root" ] || [ -z "$(ls -A "$root")" ] || die "$root exists and is not a Katap checkout; move it away first."
        log "installing Katap $tag."
        git -c core.hooksPath=/dev/null clone --quiet --no-checkout "$repo_url" "$root" || die "could not clone $repo_url."
    else
        local changes
        changes="$(g status --porcelain 2>&1)" || die "could not read $root with git ($changes); nothing was changed."
        [ -z "$changes" ] || die "$root has local changes, which an upgrade would lose; nothing was changed:"$'\n'"$changes"
        log "upgrading Katap to $tag."
        # Only this release's tag, into FETCH_HEAD: local tags are never rewritten.
        g fetch --quiet "$repo_url" "refs/tags/$tag" || die "could not fetch $tag from $repo_url; nothing was changed."
    fi
    g cat-file -e "$commit^{commit}" 2>/dev/null || die "$repo_url does not have $commit; nothing was changed."
    g checkout --quiet --detach "$commit"
    [ "$(g rev-parse HEAD)" = "$commit" ] || die "$root is not at $commit after the checkout."

    install -d -m 0755 "$(dirname "$release_file")"
    local tmp
    tmp="$(mktemp "$release_file.XXXXXX")"
    printf 'tag=%s\ncommit=%s\n' "$tag" "$commit" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$release_file"
    log "Katap $tag (${commit:0:12}) is at $root."

    exec "$provision" "${pass[@]}"
}

# <a> >= <b>, both X.Y.Z.
version_at_least() {
    local a b i
    IFS=. read -ra a <<<"$1"
    IFS=. read -ra b <<<"$2"
    for i in 0 1 2; do
        [ "${a[$i]}" -eq "${b[$i]}" ] || { [ "${a[$i]}" -gt "${b[$i]}" ]; return; }
    done
}

main "$@"
