#!/usr/bin/env bash
#
# The Katap action's one step (action.yml): resolve the image to a digest, ask the
# server to deploy it over the application's restricted SSH key, then check the
# public URL.
#
# It decides nothing the server does not check again. The server's forced command
# binds this key to one project and its components, and the server verifies the
# digest's repository and build provenance against its own settings before it
# pulls anything.
#
# Input (environment): KATAP_HOST, KATAP_USER, KATAP_SSH_KEY, KATAP_KNOWN_HOSTS,
# KATAP_PROJECT, KATAP_COMPONENT, KATAP_IMAGE, KATAP_MIGRATE_IMAGE, KATAP_REGISTRY,
# KATAP_REGISTRY_USER, KATAP_REGISTRY_TOKEN, KATAP_URL, KATAP_SMOKE_BODY.
# Test seams: KATAP_DOCKER, KATAP_SSH.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${KATAP_DOCKER:-docker}"
SSH="${KATAP_SSH:-ssh}"
REGISTRY="${KATAP_REGISTRY:-ghcr.io}"

[[ "${KATAP_PROJECT:-}" =~ ^[a-z][a-z0-9-]{0,29}$ ]] || die "project: expected a Katap project name."
[[ "${KATAP_COMPONENT:-}" =~ ^[a-z][a-z0-9]{0,19}$ ]] || die "component: expected a Katap component name."
[ -n "${KATAP_HOST:-}" ] && [ -n "${KATAP_SSH_KEY:-}" ] || die "host and ssh-key are required."
[[ "$REGISTRY" =~ ^[a-z0-9.-]+(:[0-9]+)?$ ]] || die "registry: expected a host name."

# Everything sensitive lives in one directory removed on exit: the key, the pinned
# host keys and the registry login.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export DOCKER_CONFIG="$work/docker"
mkdir -p "$DOCKER_CONFIG"

DIGEST_RE='^([a-z0-9][a-z0-9._/:-]*)@(sha256:[0-9a-f]{64})$'
TAG_RE='^([a-z0-9][a-z0-9._/-]*(:[0-9]+)?[a-z0-9._/-]*):([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$'

# Refuses a reference that is neither form, and a tag that is not on $REGISTRY:
# the registry token never goes to a host taken from the input. Prints "digest"
# or "tag".
check_ref() {
    if [[ "$1" =~ $DIGEST_RE ]]; then
        echo digest
    elif [[ "$1" =~ $TAG_RE ]]; then
        [ "${BASH_REMATCH[1]%%/*}" = "$REGISTRY" ] || die "'${BASH_REMATCH[1]}' is not on $REGISTRY; set the registry input, or pass a digest."
        echo tag
    else
        die "'$1' is neither <repository>:<tag> nor <repository>@sha256:<digest> (lowercase repository)."
    fi
}

# <repository>:<tag> or <repository>@sha256:<digest> → <repository>@sha256:<digest>.
resolve() {
    local requested="$1" digest
    if [[ "$requested" =~ $DIGEST_RE ]]; then
        printf '%s@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi
    [[ "$requested" =~ $TAG_RE ]] || die "'$requested' is not a tag."
    local repo="${BASH_REMATCH[1]}"
    digest="$("$DOCKER" buildx imagetools inspect "$requested" --format '{{json .Manifest}}' | jq -r '.digest')"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not resolve $requested to a digest."
    printf '%s@%s' "$repo" "$digest"
}

image_ref="${KATAP_IMAGE:?image is required}"
migrate_ref="${KATAP_MIGRATE_IMAGE:-}"
if [ -n "$migrate_ref" ] && [[ "$migrate_ref" != *@sha256:* ]] && [[ "${migrate_ref##*/}" != *:* ]]; then
    # A bare repository takes the runtime's tag: the publish workflow gives both
    # images the same tags, so one tag names the pair.
    [[ "$image_ref" != *@sha256:* ]] || die "migrate-image: pass a digest when image is a digest."
    migrate_ref="$migrate_ref:${image_ref##*:}"
fi

# Every reference is checked before the registry is contacted, then the token is
# used once, for $REGISTRY only, and only when a tag needs resolving.
kinds="$(check_ref "$image_ref")"
[ -z "$migrate_ref" ] || kinds+=" $(check_ref "$migrate_ref")"
if [[ " $kinds " == *" tag "* ]] && [ -n "${KATAP_REGISTRY_TOKEN:-}" ]; then
    printf '%s' "$KATAP_REGISTRY_TOKEN" | "$DOCKER" login "$REGISTRY" -u "${KATAP_REGISTRY_USER:-katap}" --password-stdin >/dev/null \
        || die "could not log in to $REGISTRY."
fi

request="deploy $KATAP_PROJECT $KATAP_COMPONENT $(resolve "$image_ref")"
[ -z "$migrate_ref" ] || request+=" migrate=$(resolve "$migrate_ref")"

# Pinned, never scanned: trusting whatever answers on port 22 would hand the
# deploy to whoever intercepts the first packet.
printf '%s\n' "${KATAP_KNOWN_HOSTS:-}" > "$work/known_hosts"
ssh-keygen -l -f "$work/known_hosts" >/dev/null 2>&1 || die "known-hosts is empty or malformed; take it from the server itself."
printf '%s\n' "$KATAP_SSH_KEY" > "$work/key"
chmod 600 "$work/key"

echo "Deploying: $request"
# The server's forced command reads this as SSH_ORIGINAL_COMMAND and refuses
# anything outside the key's project and components. The deploy keeps running on
# the server if this connection drops.
"$SSH" -i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$work/known_hosts" \
    -o ForwardAgent=no -o ServerAliveInterval=30 \
    "${KATAP_USER:-deploy}@$KATAP_HOST" "$request"
rm -f "$work/key"

if [ -n "${KATAP_URL:-}" ]; then
    sh "$HERE/../lib/smoke-check.sh" "$KATAP_URL" "${KATAP_SMOKE_BODY:-}"
fi
