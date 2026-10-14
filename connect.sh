#!/usr/bin/env bash
#
# Connects your applications' GitHub repositories to a Katap server: run it on
# your own computer, with your own ssh and gh logins.
#
#   curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/connect.sh | bash -s -- root@203.0.113.10
#   curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/connect.sh | bash -s -- root@203.0.113.10 shop
#
# It reads, over SSH, the components the server's /srv/katap.json declares, and,
# after you confirm, for each component and environment not yet connected:
#   1. creates the repository's GitHub environment, limited to its branches (an
#      existing one must already be limited to exactly those);
#   2. sets the secrets and variables examples/deploy.yml reads;
#   3. makes a deploy key in a temporary directory on this computer, authorises
#      its public half on the server for that component only, and sets it last;
#   4. deletes the key; GitHub holds the only copy.
# An environment connected before keeps its key; its secrets and variables are
# brought up to date.
# Then it prints the one command that adds .github/workflows/deploy.yml, pinned
# to the release the server runs; committing it is yours, and so is adding
# required reviewers to production.
#
# Everything the server says is data: each value is checked here before use, the
# server's release must be the commit GitHub has for that tag, and its host key
# must be the one your own known_hosts already trusts. Needs bash, ssh,
# ssh-keygen, jq and gh (signed in as an administrator of the repositories), and
# SSH to the server as root or a user with passwordless sudo.
#
# Works on macOS's bash 3.2: no associative arrays, no mapfile.
set -euo pipefail

# The server's own rules for each value (bin/katap), restated because this script
# runs alone on your computer; tests/run.sh checks the two copies are identical.
PROJECT_RE='^[a-z][a-z0-9-]{0,29}$'
COMPONENT_RE='^[a-z][a-z0-9]{0,19}$'
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9_.-]*[A-Za-z0-9_-][A-Za-z0-9_.-]*$'
IMAGE_RE='^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9._-]+)+$'
IPV4_RE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'

main() {
    local SSH="${KATAP_SSH:-ssh}" GH="${KATAP_GH:-gh}" TTY="${KATAP_TTY:-/dev/tty}"
    local KATAP_REPO=jaylordibe/katap DEPLOY_USER="${KATAP_DEPLOY_USER:-deploy}"

    die() { echo "connect: $*" >&2; exit 1; }
    log() { echo "connect: $*"; }

    [ "$#" -ge 1 ] || die "usage: connect.sh <user@server> [<project>...]"
    local target="$1"
    shift
    [[ "$target" =~ ^([a-z_][a-z0-9_-]*@)?[A-Za-z0-9.-]+$ ]] || die "'$target' is not user@host."
    local only=" $* "
    local p
    for p in "$@"; do
        [[ "$p" =~ $PROJECT_RE ]] || die "'$p' is not a project name."
    done

    local tool
    for tool in "$SSH" ssh-keygen jq "$GH"; do
        command -v "$tool" >/dev/null || die "$tool is not installed."
    done
    "$GH" auth status >/dev/null 2>&1 || die "gh is not signed in; run: gh auth login"

    local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes)

    # --- What the server says, checked --------------------------------------------
    local info
    info="$("$SSH" "${ssh_opts[@]}" -- "$target" sudo -n -u "$DEPLOY_USER" /srv/katap/bin/katap release-info)" \
        || die "could not read the server's release over SSH (is $target in your known_hosts, and does it allow sudo without a password?)."

    local head
    # One value per field: whitespace or a control character anywhere (the host
    # key's one space aside) could split a row into a component of its own.
    head="$(jq -r '
        if type == "object" and ([.tag, .commit, .host, .hostkey] | all(type == "string")) and (.components | type) == "array"
            and (.components | all(type == "object" and ([.project, .component, .environment, .repo, .image, .image_migrate, .domain, .smoke_path] | all(type == "string"))))
            and ([.tag, .commit, .host, (.components[] | .[])] | all(test("[[:space:][:cntrl:]]") | not))
            and (.hostkey | test("[[:cntrl:]]") | not)
        then [.tag, .commit, .host, .hostkey] | join("\u001f") else "invalid" end' <<<"$info" 2>/dev/null)" \
        || die "the server's answer is not JSON."
    [ "$head" != invalid ] || die "the server's answer is not a release description."
    local tag commit host hostkey
    IFS=$'\x1f' read -r tag commit host hostkey <<<"$head"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the server names no release ('$tag')."
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "the server names no commit."
    [[ "$host" =~ $IPV4_RE ]] || die "the server's host ('$host') is not an IPv4 address."
    [[ "$hostkey" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*$ ]] || die "the server's host key is not an ed25519 key."

    # The host key must be one this computer already trusts for this server: the
    # key every deploy will pin is never learned from the network.
    local cfg hostname port files name file trusted=false
    cfg="$("$SSH" -G -- "$target")" || die "could not read the ssh configuration for $target."
    hostname="$(awk '$1 == "hostname" { print $2; exit }' <<<"$cfg")"
    port="$(awk '$1 == "port" { print $2; exit }' <<<"$cfg")"
    files="$(awk '$1 == "userknownhostsfile" { $1 = ""; print; exit }' <<<"$cfg")"
    name="$hostname"
    [ "${port:-22}" = 22 ] || name="[$hostname]:$port"
    for file in $files; do
        file="${file/#\~/$HOME}"
        [ -f "$file" ] || continue
        if ssh-keygen -F "$name" -f "$file" 2>/dev/null | grep -v '^#' | awk '{ print $2 " " $3 }' | grep -qxF -- "$hostkey"; then
            trusted=true
        fi
    done
    [ "$trusted" = true ] || die "the server's ed25519 host key is not in your known_hosts for $name. Check its fingerprint with the provider's console ($(printf '%s\n' "$hostkey" | ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }')), then connect once with: ssh -o HostKeyAlgorithms=ssh-ed25519 $target true"

    # The release must be the commit GitHub has for that tag: the pinned commit is
    # the code that will hold every deploy key.
    local ref object type github_commit
    ref="$("$GH" api "repos/$KATAP_REPO/git/ref/tags/$tag" --jq '[.object.type, .object.sha] | join(" ")')" \
        || die "GitHub has no release $tag of $KATAP_REPO."
    read -r type object <<<"$ref"
    if [ "$type" = tag ]; then
        github_commit="$("$GH" api "repos/$KATAP_REPO/git/tags/$object" --jq '.object.sha')" || die "could not read tag $tag on GitHub."
    else
        github_commit="$object"
    fi
    [ "$github_commit" = "$commit" ] \
        || die "the server runs ${commit:0:12} as $tag, but GitHub's $tag is ${github_commit:0:12}; reinstall the server with install.sh."

    # The components, each value checked.
    local rows row
    rows="$(jq -r '.components[] | [.project, .component, .environment, .repo, .image, .image_migrate, .domain, .smoke_path] | map(tostring) | join("\u001f")' <<<"$info")" \
        || die "the server's component list is malformed."
    local todo=() refresh=() repos=' ' pairs=' ' pair project component environment repo image image_migrate domain smoke_path
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        IFS=$'\x1f' read -r project component environment repo image image_migrate domain smoke_path <<<"$row"
        [[ "$project" =~ $PROJECT_RE ]] || die "the server sent an invalid project name."
        [[ "$component" =~ $COMPONENT_RE ]] || die "the server sent an invalid component name."
        case "$environment" in production|staging) ;; *) die "the server sent an invalid environment." ;; esac
        [[ "$repo" =~ $REPO_RE ]] || die "the server sent an invalid repository."
        [[ "$image" =~ $IMAGE_RE ]] || die "the server sent an invalid image."
        [ -z "$image_migrate" ] || [ "$image_migrate" = "$image-migrate" ] || die "the server sent an invalid migrate image."
        [ -z "$domain" ] || [[ "$domain" =~ $DOMAIN_RE ]] || die "the server sent an invalid domain."
        [[ "$smoke_path" =~ ^/[A-Za-z0-9._/-]*$ ]] || die "the server sent a smoke path this script cannot use as a URL ('$smoke_path')."
        # One environment holds one component's names and key.
        pair="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')|$environment"
        [[ "$pairs" != *" $pair "* ]] || die "the server lists $repo twice for $environment; a repository deploys one component per environment."
        pairs+="$pair "
        [ "$only" = "  " ] || [[ "$only" == *" $project "* ]] || continue
        if connected "$repo" "$environment"; then
            refresh+=("$row")
        else
            todo+=("$row")
        fi
        [[ "$repos" == *" $repo "* ]] || repos+="$repo "
    done <<<"$rows"

    [ "$repos" != ' ' ] || die "the server's katap.json declares no component${*:+ in $*}."

    # --- Confirm ---------------------------------------------------------------------
    echo
    echo "Server $host runs Katap $tag (${commit:0:12}, matches GitHub)."
    if [ "${#todo[@]}" -gt 0 ]; then
        echo "This will, for each of these, make a deploy key, authorise it on the server for that"
        echo "component only, and set the GitHub environment's secrets and variables:"
        for row in "${todo[@]}"; do
            IFS=$'\x1f' read -r project component environment repo _ <<<"$row"
            printf '  %-40s environment %-11s -> %s/%s\n' "$repo" "$environment" "$project" "$component"
        done
    fi
    echo "The values it sets, per component:"
    for row in ${todo[@]+"${todo[@]}"} ${refresh[@]+"${refresh[@]}"}; do
        IFS=$'\x1f' read -r project component environment repo image image_migrate domain smoke_path <<<"$row"
        printf '  %s/%s: image %s%s%s\n' "$project" "$component" "$image" "${image_migrate:+, migrate $image_migrate}" "${domain:+, checks https://$domain$smoke_path}"
    done
    if [ "${#refresh[@]}" -gt 0 ]; then
        echo "These are connected already; their address and variables are brought up to date, their key kept:"
        for row in "${refresh[@]}"; do
            IFS=$'\x1f' read -r project component environment repo _ <<<"$row"
            printf '  %-40s environment %-11s -> %s/%s\n' "$repo" "$environment" "$project" "$component"
        done
    fi
    echo "In each repository below it also sets the repository-wide variable PUBLISH_ENABLED=true"
    echo "(publishing on):"
    for repo in $repos; do echo "  $repo"; done
    local answer=''
    printf 'Continue? [y/N] '
    { IFS= read -r answer < "$TTY"; } 2>/dev/null || answer=''
    case "$answer" in y|Y|yes|YES) ;; *) die "nothing was changed." ;; esac

    # --- Keys, environments, secrets -----------------------------------------------
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/katap-connect.XXXXXX")"
    # shellcheck disable=SC2064 # expanded now: the trap runs after main's locals are gone
    trap "rm -rf '$work'" EXIT
    chmod 700 "$work"
    for row in ${refresh[@]+"${refresh[@]}"}; do
        IFS=$'\x1f' read -r project component environment repo image image_migrate domain smoke_path <<<"$row"
        log "updating $repo ($environment)."
        ensure_environment "$repo" "$environment"
        set_settings
    done
    for row in ${todo[@]+"${todo[@]}"}; do
        IFS=$'\x1f' read -r project component environment repo image image_migrate domain smoke_path <<<"$row"
        log "connecting $repo ($environment) to $project/$component."
        # The environment, limited to its branches, exists before any key does:
        # its secrets are readable by every workflow run that may use it. Every
        # GitHub write that can fail comes before the key is authorised, so a
        # failure leaves no key on the server that nobody holds.
        ensure_environment "$repo" "$environment"
        set_settings
        rm -f "$work/key" "$work/key.pub"
        (umask 077 && ssh-keygen -q -t ed25519 -N '' -C "katap $project/$component $environment" -f "$work/key")
        # The public half on standard input: no key in a remote command line.
        "$SSH" "${ssh_opts[@]}" -- "$target" sudo -n /srv/katap/host/provision.sh --ci-key - \
            --ci-env "$environment" --ci-project "$project" --ci-component "$component" < "$work/key.pub" \
            || die "the server refused the key for $project/$component; no key was set in $repo."
        # Last: an environment that has KATAP_SSH_KEY is one connect.sh finished.
        "$GH" secret set KATAP_SSH_KEY --env "$environment" --repo "$repo" < "$work/key" >/dev/null
        rm -f "$work/key" "$work/key.pub"
    done

    # --- deploy.yml ---------------------------------------------------------------------
    # One file, the same in every repository: the example at the release the server
    # runs, with its pin filled in. Built here from the verified commit and tag.
    echo
    log "done. In each repository's checkout, add the deploy workflow and commit it:"
    echo
    echo "  mkdir -p .github/workflows && curl -fsSL https://raw.githubusercontent.com/$KATAP_REPO/$commit/examples/deploy.yml \\"
    echo "    | sed 's/katap@0\\{40\\} # .*/katap@$commit # $tag/' > .github/workflows/deploy.yml"
    echo
    log "Then, in Settings → Environments → production, add required reviewers and turn on"
    log "\"Prevent self-review\":"
    for repo in $repos; do log "  https://github.com/$repo/settings/environments"; done
}

# Whether <repo>'s <environment> already holds a deploy key from an earlier run.
# Only "not found" means no; any other failure stops, before a key is made.
connected() {
    local err
    err="$(mktemp)"
    if "$GH" api "repos/$1/environments/$2/secrets/KATAP_SSH_KEY" >/dev/null 2>"$err"; then
        rm -f "$err"
        return 0
    fi
    if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 1; fi
    die "could not read $1's $2 environment ($(tail -n 1 "$err"; rm -f "$err")); check that your gh login administers $1."
}

# Creates <repo>'s <environment> with deployments limited to its branches (main,
# and staging for staging), or checks an existing one is limited to exactly
# those. An existing environment is never rewritten: its reviewers stay as they are.
ensure_environment() {
    local repo="$1" environment="$2" policy err branch want='main' have
    [ "$environment" = production ] || want='main staging'
    err="$(mktemp)"
    if policy="$("$GH" api "repos/$repo/environments/$environment" --jq '.deployment_branch_policy | if . == null then "none" elif .custom_branch_policies then "custom" else "protected" end' 2>"$err")"; then
        rm -f "$err"
        [ "$policy" = custom ] && have="$("$GH" api "repos/$repo/environments/$environment/deployment-branch-policies" \
            --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | sort | join(" ")')" \
            && [ "$have" = "$(for branch in $want; do printf 'branch:%s\n' "$branch"; done | sort | tr '\n' ' ' | sed 's/ $//')" ] \
            || die "$repo's $environment environment must allow deployments from exactly: $want (it allows ${have:-$policy}); set its deployment branches in https://github.com/$repo/settings/environments, then run again. No key was made."
        return 0
    fi
    grep -q 'HTTP 404' "$err" || die "could not read $repo's $environment environment ($(tail -n 1 "$err"; rm -f "$err"))."
    rm -f "$err"
    printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
        | "$GH" api -X PUT "repos/$repo/environments/$environment" --input - >/dev/null \
        || die "could not create the $environment environment in $repo."
    for branch in main $( [ "$environment" = production ] || echo staging ); do
        "$GH" api -X POST "repos/$repo/environments/$environment/deployment-branch-policies" -f "name=$branch" -f type=branch >/dev/null \
            || die "could not limit $repo's $environment environment to $branch."
    done
}

# The secrets and variables examples/deploy.yml reads, except the key, for the
# row in the caller's variables. Values that no longer apply are removed.
set_settings() {
    local on=(--env "$environment" --repo "$repo")
    "$GH" secret set KATAP_HOST "${on[@]}" --body "$host" >/dev/null
    "$GH" secret set KATAP_KNOWN_HOSTS "${on[@]}" --body "$host $hostkey" >/dev/null
    "$GH" variable set KATAP_PROJECT "${on[@]}" --body "$project" >/dev/null
    "$GH" variable set KATAP_COMPONENT "${on[@]}" --body "$component" >/dev/null
    "$GH" variable set KATAP_IMAGE "${on[@]}" --body "$image" >/dev/null
    if [ -n "$image_migrate" ]; then
        "$GH" variable set KATAP_MIGRATE_IMAGE "${on[@]}" --body "$image_migrate" >/dev/null
    else
        "$GH" variable delete KATAP_MIGRATE_IMAGE "${on[@]}" >/dev/null 2>&1 || true
    fi
    if [ -n "$domain" ]; then
        "$GH" variable set KATAP_URL "${on[@]}" --body "https://$domain$smoke_path" >/dev/null
    else
        "$GH" variable delete KATAP_URL "${on[@]}" >/dev/null 2>&1 || true
    fi
    "$GH" variable set PUBLISH_ENABLED --repo "$repo" --body true >/dev/null
}

main "$@"
