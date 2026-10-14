#!/usr/bin/env bash
#
# Turns a deploy request into the exact digests to deploy, and refuses anything
# whose provenance does not trace back to the component's own publish workflow.
#
# Input (environment): ENVIRONMENT, PROJECT, COMPONENT, IMAGE, MIGRATE_IMAGE,
# GITHUB_SHA. Output ($GITHUB_OUTPUT): request (the words `kit ssh-dispatch`
# receives), smoke_url, smoke_body.
#
# Requires docker (logged in to the registry), gh (GH_TOKEN able to read the source
# repository's attestations) and jq; all present on GitHub's Ubuntu runners.
# tests/run.sh runs it against stub docker and gh.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*" >&2; }
conf() { bin/kit conf "$PROJECT" "$COMPONENT" "$1"; }

IMAGE="${IMAGE:?IMAGE is not set}"
case "$ENVIRONMENT" in
    production|staging) ;;
    *) die "unknown environment '$ENVIRONMENT'." ;;
esac
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA is not a commit."

# Validates the names and that the component exists.
image="$(conf image)"
image_migrate="$(conf image_migrate)"
source_repo="$(conf source_repo)"
provenance="$(conf provenance)"
[ "$(conf environment)" = "$ENVIRONMENT" ] \
    || die "projects/$PROJECT/$COMPONENT.conf is a $(conf environment) component; refusing to deploy it to $ENVIRONMENT."
[ -n "$image" ] && [[ "$image" != *OWNER/REPO* ]] || die "set image= in projects/$PROJECT/$COMPONENT.conf."

case "${provenance:-attested}" in
    attested)
        [[ "$source_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$source_repo" != OWNER/REPO ]] \
            || die "set source_repo= in projects/$PROJECT/$COMPONENT.conf."
        ;;
    none)
        warn "projects/$PROJECT/$COMPONENT.conf sets provenance=none: anyone able to push to $image can deploy to $ENVIRONMENT."
        ;;
    *) die "provenance= must be 'attested' or 'none'." ;;
esac

# The source commit an image was built from, per its attestation. Production
# accepts only builds of main; staging also accepts builds of staging.
verify() {
    local subject="$1" ref out
    local refs=(refs/heads/main)
    [ "$ENVIRONMENT" = production ] || refs+=(refs/heads/staging)
    for ref in "${refs[@]}"; do
        if out="$(gh attestation verify "oci://$subject" --repo "$source_repo" \
            --signer-workflow "$source_repo/.github/workflows/publish-image.yml" \
            --source-ref "$ref" --deny-self-hosted-runners --format json 2>/dev/null)"; then
            jq -r '[.[].verificationResult.signature.certificate.sourceRepositoryDigest // empty][0] // ""' <<<"$out"
            return 0
        fi
    done
    die "$subject has no build-provenance attestation from $source_repo's publish workflow on ${refs[*]}; refusing to deploy it."
}

# <repo>:<tag> or <repo>@sha256:<digest> → <repo>@sha256:<digest>, for this
# component's repository only.
resolve() {
    local requested="$1" expected="$2" repo digest
    if [[ "$requested" =~ ^([a-z0-9][a-z0-9._/:-]*)@(sha256:[0-9a-f]{64})$ ]]; then
        repo="${BASH_REMATCH[1]}"
        digest="${BASH_REMATCH[2]}"
    elif [[ "$requested" =~ ^([a-z0-9][a-z0-9._/-]*(:[0-9]+)?[a-z0-9._/-]*):([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$ ]]; then
        repo="${BASH_REMATCH[1]}"
        # Before any registry is contacted: never an arbitrary host from the input.
        [ "$repo" = "$expected" ] || die "'$repo' is not this component's repository ($expected)."
        digest="$(docker buildx imagetools inspect "$requested" --format '{{json .Manifest}}' | jq -r '.digest')"
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not resolve $requested to a digest."
    else
        die "'$requested' is neither <repository>:<tag> nor <repository>@sha256:<digest>."
    fi
    [ "$repo" = "$expected" ] || die "'$repo' is not this component's repository ($expected)."
    printf '%s@%s' "$repo" "$digest"
}

runtime="$(resolve "$IMAGE" "$image")"
request="deploy $PROJECT $COMPONENT $runtime"
runtime_commit=''
[ "${provenance:-attested}" = none ] || runtime_commit="$(verify "$runtime")"

if [ -n "$image_migrate" ]; then
    migrate_requested="${MIGRATE_IMAGE:-}"
    if [ -z "$migrate_requested" ]; then
        # The migrate image is published under the same tags as the runtime, so a tag
        # names both. A digest names one image only.
        [[ "$IMAGE" == *@sha256:* ]] && die "this component also needs migrate_image (the $image_migrate digest from the same publish run)."
        migrate_requested="$image_migrate:${IMAGE##*:}"
    fi
    migrate="$(resolve "$migrate_requested" "$image_migrate")"
    if [ "${provenance:-attested}" != none ]; then
        migrate_commit="$(verify "$migrate")"
        # The schema step must come from the same commit as the code that runs on it.
        # Fails closed: a pair that cannot be compared is not deployed.
        [ -n "$runtime_commit" ] && [ -n "$migrate_commit" ] \
            || die "could not read the source commit from the attestations, so the runtime and migrate images cannot be shown to match."
        [ "$runtime_commit" = "$migrate_commit" ] \
            || die "the runtime ($runtime_commit) and migrate ($migrate_commit) images were built from different commits."
    fi
    request+=" migrate=$migrate"
elif [ -n "${MIGRATE_IMAGE:-}" ]; then
    die "this component has no migrate image."
fi
# The host refuses unless its checkout is this commit (bin/kit release).
request+=" kit=$GITHUB_SHA"

domain="$(conf domains)"
domain="${domain%% *}"
smoke_url=''
[ -z "$domain" ] || smoke_url="https://$domain$(conf smoke_path)"

{
    echo "request=$request"
    echo "smoke_url=$smoke_url"
    echo "smoke_body=$(conf smoke_body)"
} >> "$GITHUB_OUTPUT"
echo "Deploying: $request"
