#!/usr/bin/env bash
#
# Katap's test suite.
#
#   tests/run.sh             static checks and unit tests (no containers started)
#   E2E=1 tests/run.sh       plus an end-to-end deploy on the local Docker daemon
#
# Everything runs inside tests/runner.Dockerfile (bash 5, flock, jq, the Docker
# CLI), the same tools Katap has on a server. The Docker socket is shared, so
# the end-to-end run uses this machine's daemon. It creates and removes only
# resources named katap-e2e* / e2e* and the katap-edge network.
#
# E2E settings:
#   E2E_LARAVEL_API   path of a laravel-api checkout to build (default ../laravel-api)
#   E2E_BASE_IMAGE    use this local image for laravel-api's FROM instead of its pinned digest
#   E2E_KEEP=1        leave the end-to-end resources running for inspection
set -euo pipefail
shopt -s nullglob

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_IMAGE='katap-test-runner:local'

if [ "${KATAP_TEST_IN_RUNNER:-}" != 1 ]; then
    docker build --quiet -t "$RUNNER_IMAGE" -f "$REPO/tests/runner.Dockerfile" "$REPO/tests" >/dev/null
    # This part runs on the developer's own bash, which may be 3.2 (macOS).
    tty=''
    [ ! -t 1 ] || tty='-t'
    # shellcheck disable=SC2086 # $tty is empty or one flag.
    exec docker run --rm $tty \
        -e KATAP_TEST_IN_RUNNER=1 -e E2E -e E2E_LARAVEL_API -e E2E_BASE_IMAGE -e E2E_KEEP \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$REPO:$REPO" -w "$REPO" \
        -v "$(cd "$REPO/.." && pwd):$(cd "$REPO/.." && pwd):ro" \
        "$RUNNER_IMAGE" bash tests/run.sh "$@"
fi

# --- Harness --------------------------------------------------------------------

WORK="$REPO/tests/.work"
rm -rf "$WORK"
mkdir -p "$WORK"

passed=0
failed=0
failures=()

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
not_ok() {
    failed=$((failed + 1))
    failures+=("$1")
    echo "  FAIL  $1"
    [ -z "${2:-}" ] || head -n 40 <<<"$2" | while IFS= read -r line; do echo "        | $line"; done
}

# check <name> <command...>: passes when the command succeeds.
check() {
    local name="$1" out
    shift
    if out="$("$@" 2>&1)"; then ok "$name"; else not_ok "$name" "$out"; fi
}

# refuses <name> <expected message> <command...>: passes when the command fails
# and says why.
refuses() {
    local name="$1" message="$2" out
    shift 2
    if out="$("$@" 2>&1)"; then
        not_ok "$name" "succeeded, expected a refusal containing: $message"$'\n'"$out"
    elif grep -qF -- "$message" <<<"$out"; then
        ok "$name"
    else
        not_ok "$name" "refused, but without: $message"$'\n'"$out"
    fi
}

section() { echo; echo "== $1"; }

# A throwaway copy of the tool with its own host directory, $K/srv, standing in
# for /srv: projects, secrets, state and the edge override live there, never in
# the tool. KATAP_SETTINGS points at a file that does not exist unless a test
# writes it, so the runner's /etc is never read.
new_katap() {
    local dir
    dir="$(mktemp -d "$WORK/katap.XXXXXX")"
    cp -R "$REPO/bin" "$REPO/lib" "$REPO/templates" "$REPO/edge" "$REPO/action" "$REPO/action.yml" "$dir/"
    mkdir -p "$dir/srv/projects"
    echo "$dir"
}

katap() { KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN="${KATAP_DISPATCH_COOLDOWN:-0}" "$K/bin/katap" "$@"; }

set_conf() { sed -i "s|^$3=.*|$3=$4|" "$K/srv/projects/$1/$2.conf"; }

fill_required() {
    # $1 project, $2 component: give every required value a placeholder.
    sed -i '/^# katap:required$/{n;s/=$/=filled-by-test/}' "$K/srv/secrets/$1/$2.env"
}

digest() { printf 'sha256:%064d' "$1"; }

seconds() {
    # Compose renders durations like 1m30s or 40s.
    local d="$1" total=0
    [[ "$d" =~ ([0-9]+)m ]] && total=$((total + BASH_REMATCH[1] * 60))
    [[ "$d" =~ ([0-9]+)s ]] && total=$((total + BASH_REMATCH[1]))
    echo "$total"
}

rendered() {
    # The merged compose configuration of a project, with placeholder secrets.
    local project="$1" fixture="$WORK/render-$1"
    mkdir -p "$fixture"
    local c
    for c in "$K/srv/projects/$project"/*.conf; do
        c="$(basename "$c" .conf)"
        : > "$fixture/$c.env"
        : > "$fixture/$c.db.env"
        : > "$fixture/$c.redis.env"
    done
    local files=() f
    for f in "$K/srv/projects/$project"/*.yml; do files+=(-f "$f"); done
    KATAP_ROOT="$K" KATAP_PROJECT="$project" KATAP_SECRETS="$fixture" \
        docker compose --project-name "$project" --project-directory "$K/srv/projects/$project" \
        --env-file /dev/null --profile '*' "${files[@]}" config --format json
}

# --- Static ---------------------------------------------------------------------

section "static"

check "shellcheck: every script" shellcheck -x "$REPO/bin/katap" "$REPO"/lib/*.sh "$REPO"/host/*.sh "$REPO"/action/*.sh "$REPO/install.sh" "$REPO/connect.sh" "$REPO/tests/run.sh" "$REPO/tests/e2e.sh"

check "every link and anchor in README.md and docs/ resolves, and every docs reference in the code names a real heading" \
    python3 "$REPO/tests/check_docs.py" "$REPO"
check "laravel-api and nestjs-api never mention Katap (they publish images; how they are deployed is not theirs)" \
    bash -c "for r in laravel-api nestjs-api; do [ ! -d '$REPO/../'\$r ] || ! grep -rIil katap '$REPO/../'\$r --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor || exit 1; done"

# connect.sh runs alone on the operator's computer, so it restates the server's
# rules for each value; the copies must stay identical.
same_rule() { [ "$(grep -m1 "^$1=" "$REPO/bin/katap")" = "$(grep -m1 "^$1=" "$REPO/connect.sh")" ]; }
check "connect.sh validates with exactly the server's rules" \
    bash -c "$(declare -f same_rule); REPO='$REPO'; for r in PROJECT_RE COMPONENT_RE DOMAIN_RE REPO_RE IMAGE_RE IPV4_RE; do same_rule \$r || { echo \$r; exit 1; }; done"
check "provision.sh and the action bind the same project and component names" \
    bash -c "for f in '$REPO/host/provision.sh' '$REPO/action/deploy.sh'; do grep -qF \"\$(sed -n \"s/^PROJECT_RE='\\(.*\\)'\$/\\1/p\" '$REPO/bin/katap' | sed 's/\\\$\$//')\" \"\$f\" && grep -qF \"\$(sed -n \"s/^COMPONENT_RE='\\(.*\\)'\$/\\1/p\" '$REPO/bin/katap' | sed 's/\\\$\$//')\" \"\$f\" || { echo \$f; exit 1; }; done"

no_match() {
    local pattern="$1"
    shift
    ! grep -rnE -- "$pattern" "$@"
}
check "no destructive data command anywhere in Katap" \
    no_match 'migrate:fresh|key:generate|passport:keys|down -v|--volumes|volume rm|docker exec ' \
    "$REPO/bin" "$REPO/lib" "$REPO/host" "$REPO/templates" "$REPO/edge"
check "the only seeder a template runs is the permission sync" \
    bash -c "! grep -rn 'db:seed' '$REPO/templates' | grep -v 'PermissionsSeeder'"
check "no template turns off Laravel's runtime config cache or startup check" \
    no_match 'APP_RUNTIME_CONFIG_CACHE|APP_CONFIG_CHECK' "$REPO/templates"
check "every fixed image in the edge and templates is pinned by digest" \
    bash -c "! grep -rhE '^\s*image:' '$REPO/edge' '$REPO/templates' | grep -v '\${IMAGE_' | grep -vE '@sha256:[0-9a-f]{64}\s*$'"

# Moved from nestjs-api test/external-exposure.e2e-spec.ts: the edge, not the
# application, now owns these, so they are asserted where the edge lives.
caddyfile="$(cat "$REPO/edge/Caddyfile")"
check "the edge has exactly one reverse_proxy, inside katap_proxy" \
    bash -c "[ \"\$(grep -cE '^[[:space:]]*reverse_proxy ' '$REPO/edge/Caddyfile')\" = 1 ] && grep -qE '^[[:space:]]reverse_proxy \{args\[0\]\} \{' '$REPO/edge/Caddyfile'"
check "no site template proxies around katap_proxy" \
    no_match 'reverse_proxy' "$REPO"/templates/*.site
check "every site template imports katap_site and proxies through katap_proxy" \
    bash -c "for f in '$REPO'/templates/*.site; do grep -qE '^\simport katap_site$' \"\$f\" && grep -qE '^\simport katap_proxy __UPSTREAM__$' \"\$f\" || exit 1; done"
check "behind Cloudflare the client address comes from CF-Connecting-IP" \
    grep -qF 'header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}' <<<"$caddyfile"
check "Cloudflare mode requires the origin-pull client certificate and Cloudflare's ranges" \
    bash -c "grep -qF 'mode require_and_verify' '$REPO/edge/Caddyfile' && grep -qF '@katap_not_cloudflare not remote_ip 173.245.48.0/20' '$REPO/edge/Caddyfile'"
check "the nestjs-api site matches exactly the Swagger subtree" \
    grep -qxF $'\t@docs path /api/docs /api/docs/*' "$REPO/templates/nestjs-api.site"

# --- add and check --------------------------------------------------------------

section "katap add / katap check"

K="$(new_katap)"
check "add laravel-api" katap add shop laravel-api api api.shop.test
check "add spa" katap add shop spa web shop.test www.shop.test
check "add nestjs-api" katap add blog nestjs-api api api.blog.test
check "add spa to a second project" katap add blog spa web blog.test
check "add node-ssr" katap add blog node-ssr ssr ssr.blog.test
check "add an internal-only component (no domain)" katap add tools spa docs
refuses "a component cannot be added twice" "already exists" katap add shop spa web other.test
refuses "a project name is validated" "invalid project name" katap add Shop spa web x.test
refuses "a component name is validated (no hyphen)" "invalid component name" katap add shop spa my-web x.test
refuses "a domain is validated" "invalid domain" katap add shop spa web 'x.test;rm'
refuses "an unknown type is refused" "unknown type" katap add shop rails api x.test
check "site.caddy routes each domain to its component" \
    bash -c "grep -qxF 'api.shop.test {' '$K/srv/projects/shop/site.caddy' && grep -qxF $'\timport katap_proxy shop-api:80' '$K/srv/projects/shop/site.caddy' && grep -qxF 'shop.test, www.shop.test {' '$K/srv/projects/shop/site.caddy' && grep -qxF $'\timport katap_proxy blog-api:3000' '$K/srv/projects/blog/site.caddy'"
check "an internal-only component gets no site" test ! -e "$K/srv/projects/tools/site.caddy"
check "katap add writes the project under the host directory, nothing into the tool" \
    bash -c "[ -f '$K/srv/projects/shop/api.conf' ] && [ ! -e '$K/projects' ] && [ -z \"\$(find '$K/bin' '$K/templates' '$K/edge' '$K/lib' -newer '$K/srv/projects/shop/api.conf' -type f)\" ]"

check "laravel-api + spa meet the project contract" katap check shop
check "nestjs-api + spa + node-ssr meet the project contract" katap check blog

shop_config="$(rendered shop)"
check "laravel worker stop grace period >= 75s (HORIZON_TIMEOUT + 15s)" \
    test "$(seconds "$(jq -r '.services["api-worker"].stop_grace_period' <<<"$shop_config")")" -ge 75
check "nestjs-api stop grace period > its 25s drain" \
    test "$(seconds "$(rendered blog | jq -r '.services.api.stop_grace_period')")" -gt 25
check "only the public services join the edge" \
    test "$(jq -r '[.services | to_entries[] | select(.value.networks | has("edge")) | .key] | sort | join(" ")' <<<"$shop_config")" = "api web"
check "the edge alias is <project>-<component>" \
    test "$(jq -r '.services.api.networks.edge.aliases[0]' <<<"$shop_config")" = "shop-api"
check "laravel runtime modes" \
    test "$(jq -r '[.services.api, .services["api-worker"], .services["api-migrate"], .services["api-scheduler"]] | map(.environment.APP_RUNTIME_MODE) | join(" ")' <<<"$shop_config")" = "api worker migrate scheduler"
check "the permission sync is the declared PermissionsSeeder one-shot" \
    test "$(jq -c '.services["api-permissions"].command' <<<"$shop_config")" = '["db:seed","--class=PermissionsSeeder","--force","--no-interaction"]'

# Each negative fixture breaks one rule of the contract in a copy of `shop`.
mutate() {
    local name="$1" message="$2" script="$3"
    rm -rf "$K/srv/projects/bad"
    cp -R "$K/srv/projects/shop" "$K/srv/projects/bad"
    python3 - "$K/srv/projects/bad" <<<"$script"
    refuses "katap check refuses: $name" "$message" katap check bad
}
mutate "a published port" "publishes ports" '
import sys; p = sys.argv[1] + "/api.yml"; s = open(p).read()
open(p, "w").write(s.replace("    environment:\n      APP_RUNTIME_MODE: api\n", "    environment:\n      APP_RUNTIME_MODE: api\n    ports:\n      - \"8080:80\"\n", 1))'
mutate "an image not pinned by digest" "is not pinned by digest" '
import sys, re; p = sys.argv[1] + "/api.yml"; s = open(p).read()
open(p, "w").write(re.sub(r"postgres:18\.6@sha256:[0-9a-f]+", "postgres:18", s))'
mutate "a one-shot service with a restart policy" "must not restart" '
import sys; p = sys.argv[1] + "/api.yml"; s = open(p).read()
open(p, "w").write(s.replace("    profiles: [cron]\n    restart: '"'"'no'"'"'", "    profiles: [cron]\n    restart: unless-stopped"))'
mutate "a long-running service without a healthcheck" "without a healthcheck" '
import sys, re; p = sys.argv[1] + "/web.yml"; s = open(p).read()
open(p, "w").write(re.sub(r"    healthcheck:\n(      .*\n)+", "", s))'
mutate "a database on the edge network" "a data service is on the edge network" '
import sys; p = sys.argv[1] + "/api.yml"; s = open(p).read()
open(p, "w").write(s.replace("    shm_size: 256mb\n", "    shm_size: 256mb\n    networks: [default, edge]\n", 1))'
mutate "a fixed hostname" "a fixed hostname" '
import sys; p = sys.argv[1] + "/api.yml"; s = open(p).read()
open(p, "w").write(s.replace("    stop_grace_period: 90s\n", "    stop_grace_period: 90s\n    hostname: worker\n", 1))'
mutate "a .conf naming a service that does not exist" "names 'api-nope'" '
import sys; p = sys.argv[1] + "/api.conf"; s = open(p).read()
open(p, "w").write(s.replace("rollout=api-worker api", "rollout=api-worker api-nope"))'
mutate "the Docker socket mounted" "mounts the Docker socket" '
import sys; p = sys.argv[1] + "/web.yml"; s = open(p).read()
open(p, "w").write(s.replace("    mem_limit: 128m\n", "    mem_limit: 128m\n    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock\n", 1))'
rm -rf "$K/srv/projects/bad"

# --- secrets --------------------------------------------------------------------

section "katap secrets"

env_get() { grep -E "^$2=" "$1" | head -n1 | cut -d= -f2-; }
unescape_pem() { printf '%b\n' "$1"; }

secrets_laravel_ok() {
    local app="$K/srv/secrets/shop/api.env" db="$K/srv/secrets/shop/api.db.env" redis="$K/srv/secrets/shop/api.redis.env" v
    v="$(env_get "$app" APP_KEY)"; [[ "$v" =~ ^base64:[A-Za-z0-9+/]{43}=$ ]] || { echo "APP_KEY: $v"; return 1; }
    for v in POSTGRES_PASSWORD APP_DB_PASSWORD; do
        [[ "$(env_get "$db" "$v")" =~ ^[0-9a-f]{64}$ ]] || { echo "$v is not 64 hex"; return 1; }
    done
    [[ "$(env_get "$redis" REDIS_PASSWORD)" =~ ^[0-9a-f]{64}$ ]] || { echo "REDIS_PASSWORD is not 64 hex"; return 1; }
    [ "$(env_get "$app" DB_PASSWORD)" = "$(env_get "$db" APP_DB_PASSWORD)" ] || { echo "DB_PASSWORD differs"; return 1; }
    [ "$(env_get "$app" REDIS_PASSWORD)" = "$(env_get "$redis" REDIS_PASSWORD)" ] || { echo "REDIS_PASSWORD differs"; return 1; }
    [ "$(env_get "$redis" REDISCLI_AUTH)" = "$(env_get "$redis" REDIS_PASSWORD)" ] || { echo "REDISCLI_AUTH differs"; return 1; }
    ! grep -q 'POSTGRES_PASSWORD' "$app" "$redis" || { echo "the superuser password is outside the database's own file"; return 1; }
    ! grep -q 'REDIS' "$db" || { echo "Redis secrets are in the database's file"; return 1; }
    [ "$(env_get "$app" APP_URL)" = https://api.shop.test ] || { echo "APP_URL"; return 1; }
    [ "$(env_get "$app" TRUSTED_PROXIES)" = 0.0.0.0/0 ] || { echo "TRUSTED_PROXIES"; return 1; }
    local private public
    private="$(env_get "$app" PASSPORT_PRIVATE_KEY)"
    public="$(env_get "$app" PASSPORT_PUBLIC_KEY)"
    [[ "$private" == '-----BEGIN PRIVATE KEY-----\n'* ]] || { echo "PASSPORT_PRIVATE_KEY is not one escaped PEM line"; return 1; }
    [ "$(unescape_pem "$private" | openssl pkey -pubout 2>/dev/null)" = "$(unescape_pem "$public")" ] \
        || { echo "the Passport public key does not belong to the private key"; return 1; }
    grep -vE '^(#.*)?$' "$app" "$db" "$redis" | grep -vE '^[^:]+:[A-Z][A-Z0-9_]*=' && { echo "a line is not KEY=VALUE"; return 1; }
    ! grep -q '{' "$app" || { echo "an unexpanded placeholder"; return 1; }
    [ "$(stat -c %a "$K/srv/secrets/shop")" = 700 ] && [ "$(stat -c %a "$app")" = 600 ] && [ "$(stat -c %a "$db")" = 600 ] && [ "$(stat -c %a "$redis")" = 600 ] \
        || { echo "permissions"; return 1; }
    [ "$(stat -c %a "$K/srv/secrets/shop/api-db-tls/server.key")" = 600 ] || { echo "TLS key permissions"; return 1; }
    openssl x509 -in "$K/srv/secrets/shop/api-db-tls/server.crt" -noout -subject | grep -q 'CN *= *api-db' || { echo "TLS certificate"; return 1; }
    local leftover=("$K/srv/secrets/shop"/.work*)
    [ "${#leftover[@]}" -eq 0 ] || { echo "a work directory was left behind"; return 1; }
}

laravel_runs=20
laravel_failures=''
for _ in $(seq 1 "$laravel_runs"); do
    rm -rf "$K/srv/secrets/shop"
    out="$(katap secrets shop api 2>&1)" || { laravel_failures+="$out"$'\n'; continue; }
    out="$(secrets_laravel_ok 2>&1)" || laravel_failures+="$out"$'\n'
done
if [ -z "$laravel_failures" ]; then ok "laravel-api secrets are well-formed in $laravel_runs fresh runs"; else not_ok "laravel-api secrets are well-formed in $laravel_runs fresh runs" "$laravel_failures"; fi

before="$(sha256sum "$K/srv/secrets/shop/api.env" "$K/srv/secrets/shop/api.db.env" "$K/srv/secrets/shop/api.redis.env" "$K/srv/secrets/shop/api-db-tls/server.key")"
refuses "secrets are never regenerated" "refusing to overwrite" katap secrets shop api
check "a refused run leaves every secret byte-identical" \
    test "$before" = "$(sha256sum "$K/srv/secrets/shop/api.env" "$K/srv/secrets/shop/api.db.env" "$K/srv/secrets/shop/api.redis.env" "$K/srv/secrets/shop/api-db-tls/server.key")"

nest_runs=100
nest_failures=''
for _ in $(seq 1 "$nest_runs"); do
    rm -rf "$K/srv/secrets/blog"
    katap secrets blog api >/dev/null 2>&1 || { nest_failures+="secrets failed"$'\n'; continue; }
    app="$K/srv/secrets/blog/api.env"
    [[ "$(env_get "$app" DATABASE_URL)" == "postgresql://app:$(env_get "$K/srv/secrets/blog/api.db.env" APP_DB_PASSWORD)@api-db:5432/app?schema=public" ]] || nest_failures+="DATABASE_URL"$'\n'
    [[ "$(env_get "$app" REDIS_URL)" == "redis://default:$(env_get "$K/srv/secrets/blog/api.redis.env" REDIS_PASSWORD)@api-redis:6379" ]] || nest_failures+="REDIS_URL"$'\n'
    [[ "$(env_get "$app" JWT_SECRET)" =~ ^[0-9a-f]{96}$ ]] || nest_failures+="JWT_SECRET"$'\n'
done
if [ -z "$nest_failures" ]; then ok "nestjs-api secrets are well-formed in $nest_runs fresh runs"; else not_ok "nestjs-api secrets are well-formed in $nest_runs fresh runs" "$(sort <<<"$nest_failures" | uniq -c)"; fi
check "nestjs-api trusts exactly the edge's fixed address" \
    test "$(env_get "$K/srv/secrets/blog/api.env" TRUST_PROXY)" = "$(grep '^CADDY_IP=' "$K/edge/edge.env" | cut -d= -f2)"
check "nestjs-api does not trust Cloudflare headers outside Cloudflare mode" \
    test "$(env_get "$K/srv/secrets/blog/api.env" TRUST_CLOUDFLARE_HEADERS)" = false
# This host's /srv/edge/edge.env overrides the tool's defaults, key by key.
mkdir -p "$K/srv/edge"
printf 'TLS_MODE=cloudflare\nCADDY_IP=10.254.0.9\n' > "$K/srv/edge/edge.env"
rm -rf "$K/srv/secrets/blog"
katap secrets blog api >/dev/null
check "nestjs-api trusts Cloudflare headers in Cloudflare mode (set in the host's edge.env)" \
    test "$(env_get "$K/srv/secrets/blog/api.env" TRUST_CLOUDFLARE_HEADERS)" = true
check "…and the overridden edge address" test "$(env_get "$K/srv/secrets/blog/api.env" TRUST_PROXY)" = 10.254.0.9
cat > "$WORK/edge-recorder" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/edge.log"
EOF
chmod +x "$WORK/edge-recorder"
: > "$WORK/edge.log"
KATAP_DOCKER="$WORK/edge-recorder" katap edge reload >/dev/null 2>&1 || true
check "the edge's compose reads the same files, defaults first, then the host's" \
    grep -qF -- "--env-file $K/edge/edge.env --env-file $K/srv/edge/edge.env" "$WORK/edge.log"
check "…and mounts the host's projects directory" bash -c "grep -q 'KATAP_PROJECTS' '$REPO/edge/compose.yml' && ! grep -q '\.\./projects' '$REPO/edge/compose.yml'"
echo TLS_MODE=cloudflare > "$K/srv/edge/edge.env"
rm -rf "$K/srv/secrets/blog"
katap secrets blog api >/dev/null
check "an override of one key keeps every other default (key by key, not the whole file)" \
    test "$(env_get "$K/srv/secrets/blog/api.env" TRUST_PROXY)" = "$(grep '^CADDY_IP=' "$K/edge/edge.env" | cut -d= -f2)"
rm -f "$K/srv/edge/edge.env"
check "provision pins the defaults into the host's edge.env once, and never rewrites it" bash -c "
    . '$REPO/host/provision.sh'
    pin_edge_settings '$K/edge/edge.env' '$WORK/pinned.env'
    grep -qxF \"\$(grep '^CADDY_IP=' '$K/edge/edge.env')\" '$WORK/pinned.env' || exit 1
    echo CADDY_IP=10.254.0.77 > '$WORK/pinned.env'
    pin_edge_settings '$K/edge/edge.env' '$WORK/pinned.env'
    grep -qxF CADDY_IP=10.254.0.77 '$WORK/pinned.env'"

# --- deploy refusals (before anything is pulled) --------------------------------

section "katap deploy refusals"

# A docker wrapper that records every pull and refuses it, so a test can prove a
# refusal happened before the deploy touched anything.
cat > "$WORK/docker-recorder" <<EOF
#!/usr/bin/env bash
if [ "\$1" = pull ]; then echo "pull \$*" >> "$WORK/pulls"; exit 1; fi
exec docker "\$@"
EOF
chmod +x "$WORK/docker-recorder"
: > "$WORK/pulls"
deploy() { KATAP_DOCKER="$WORK/docker-recorder" katap deploy "$@"; }

D64="ghcr.io/acme/shop-api@$(digest 1)"
SHA40="$(printf 'a%.0s' $(seq 1 40))"
refuses "a required secret is still empty" "required values are empty" deploy shop api "$D64"
fill_required shop api
refuses "no image repository configured, naming the file to fix" "set image= in $K/srv/projects/shop/api.conf" deploy shop api "$D64"
set_conf shop api image ghcr.io/acme/shop-api
refuses "a tag instead of a digest" "is not pinned by digest" deploy shop api ghcr.io/acme/shop-api:latest
refuses "a different repository" "is not this component's repository" deploy shop api "ghcr.io/evil/shop-api@$(digest 1)"
refuses "a repository that only starts the same" "is not this component's repository" deploy shop api "ghcr.io/acme/shop-api-evil@$(digest 1)"
refuses "an unknown image target" "unknown image target" deploy shop api "$D64" worker="$D64"
refuses "a migrate image for a component without one" "has no migrate image" deploy shop api "$D64" migrate="$D64"
refuses "an unknown component" "unknown component" deploy shop nope "$D64"
set_conf blog api image ghcr.io/acme/blog-api
set_conf blog api image_migrate ghcr.io/acme/blog-api-migrate
fill_required blog api
refuses "a nestjs-api deploy without its migrate image" "also needs migrate=" deploy blog api "ghcr.io/acme/blog-api@$(digest 2)"
check "no refused deploy pulled anything" test ! -s "$WORK/pulls"

# --- provenance, verified by the host ----------------------------------------------

section "katap deploy verifies build provenance itself (stub gh)"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# `gh attestation verify oci://<subject> … --source-ref <ref> …`: records the call and
# the token; accepts only GH_ACCEPT_REF, and reports GH_COMMIT (GH_MIGRATE_COMMIT
# for a -migrate image).
echo "token=$GH_TOKEN $*" >> "$GH_LOG"
[ -z "${GH_SLEEP:-}" ] || sleep "$GH_SLEEP"
ref=''
prev=''
for arg in "$@"; do [ "$prev" = --source-ref ] && ref="$arg"; prev="$arg"; done
[ "$ref" = "${GH_ACCEPT_REF:-refs/heads/main}" ] || { echo "${GH_STDERR:-no attestations found}" >&2; exit 1; }
commit="${GH_COMMIT:-cccccccccccccccccccccccccccccccccccccccc}"
[[ "$3" != *-migrate@* ]] || commit="${GH_MIGRATE_COMMIT:-$commit}"
[ -n "${GH_NO_COMMIT:-}" ] && { echo '[{"verificationResult":{}}]'; exit 0; }
printf '[{"verificationResult":{"signature":{"certificate":{"sourceRepositoryDigest":"%s"}}}}]\n' "$commit"
STUB
chmod +x "$STUBS/gh"
GH_LOG="$WORK/gh.log"
# vdeploy [VAR=value...] -- <katap deploy args>: a deploy with the stub gh.
vdeploy() {
    local vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    : > "$GH_LOG"
    : > "$WORK/pulls"
    env KATAP_GH="$STUBS/gh" GH_LOG="$GH_LOG" KATAP_GH_TOKEN=test-token KATAP_DOCKER="$WORK/docker-recorder" \
        KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "${vars[@]}" "$K/bin/katap" deploy "$@"
}
refuses "no source repository configured" "set source_repo=" vdeploy -- shop api "$D64"
set_conf shop api source_repo acme/shop-api
set_conf blog api source_repo acme/blog-api
refuses "no GitHub token on the host" "set KATAP_GH_TOKEN" vdeploy KATAP_GH_TOKEN= -- shop api "$D64"
refuses "an image without an attestation is refused" "could not verify that" \
    vdeploy GH_ACCEPT_REF=none -- shop api "$D64"
check "…before anything is pulled" test ! -s "$WORK/pulls"
refuses "production accepts only a build of main" "could not verify that" \
    vdeploy GH_ACCEPT_REF=refs/heads/staging -- shop api "$D64"
check "…and asks for refs/heads/main and nothing else" \
    bash -c "grep -q -- '--source-ref refs/heads/main' '$GH_LOG' && ! grep -q 'refs/heads/staging' '$GH_LOG'"
check "every verification names the repository and signer workflow, refuses self-hosted runners and uses the host's token" \
    bash -c "grep -q -- '--repo acme/shop-api ' '$GH_LOG' && grep -q -- '--signer-workflow acme/shop-api/.github/workflows/publish-image.yml' '$GH_LOG' && grep -q -- '--deny-self-hosted-runners' '$GH_LOG' && grep -q '^token=test-token ' '$GH_LOG'"
sed -i '/^provenance=/d' "$K/srv/projects/shop/api.conf"
refuses "a .conf without provenance= is verified (attested is the default)" "could not verify that" \
    vdeploy GH_ACCEPT_REF=none -- shop api "$D64"
echo provenance=attested >> "$K/srv/projects/shop/api.conf"
refuses "a gh failure is reported with gh's own words" "gh said: main: HTTP 401: Bad credentials" \
    vdeploy GH_ACCEPT_REF=none GH_STDERR='HTTP 401: Bad credentials' -- shop api "$D64"
refuses "a timeout that is not whole seconds is refused, never ignored" "KATAP_GH_TIMEOUT must be whole seconds" \
    vdeploy KATAP_GH_TIMEOUT=1m -- shop api "$D64"
started=$SECONDS
refuses "a GitHub that does not answer is cut off" "GitHub did not answer" \
    vdeploy GH_SLEEP=30 KATAP_GH_TIMEOUT=1 -- shop api "$D64"
check "…well before it would have answered" test $((SECONDS - started)) -lt 20
printf 'KATAP_GH_TIMEOUT=1\n' > "$K/katap.env"
refuses "the timeout can be set in the host's settings file" "GitHub did not answer" vdeploy GH_SLEEP=30 -- shop api "$D64"
rm -f "$K/katap.env"
vdeploy -- shop api "$D64" >/dev/null 2>&1 || true
check "an attested build of main goes on to the pull" test -s "$WORK/pulls"
cp -R "$K/srv/projects/shop" "$K/srv/projects/stg"
set_conf stg api environment staging
fill_required_dir() { mkdir -p "$K/srv/secrets/$2"; cp -R "$K/srv/secrets/$1/." "$K/srv/secrets/$2/"; }
fill_required_dir shop stg
vdeploy GH_ACCEPT_REF=refs/heads/staging -- stg api "$D64" env=staging >/dev/null 2>&1 || true
check "a staging component accepts a build of the staging branch" test -s "$WORK/pulls"
refuses "a staging refusal names what gh said for each branch it tried" "gh said: main: HTTP 503; staging: HTTP 503" \
    vdeploy GH_ACCEPT_REF=none GH_STDERR='HTTP 503' -- stg api "$D64" env=staging
rm -rf "$K/srv/projects/stg" "$K/srv/secrets/stg" "$K/srv/state/stg"
refuses "runtime and migrate images from different commits are refused" "built from different commits" \
    vdeploy GH_MIGRATE_COMMIT=dddddddddddddddddddddddddddddddddddddddd -- blog api "ghcr.io/acme/blog-api@$(digest 2)" "migrate=ghcr.io/acme/blog-api-migrate@$(digest 3)"
refuses "a release whose source commit cannot be read is refused (fails closed)" "could not read the source commit" \
    vdeploy GH_NO_COMMIT=1 -- shop api "$D64"
check "no refused deploy pulled anything" test ! -s "$WORK/pulls"
printf 'KATAP_GH_TOKEN="from-settings-file"\r\n' > "$K/katap.env"
vdeploy KATAP_GH_TOKEN= -- shop api "$D64" >/dev/null 2>&1 || true
check "the token is read from the host's settings file, its quotes removed as systemd does" grep -q '^token=from-settings-file ' "$GH_LOG"
vdeploy KATAP_GH_TOKEN=from-environment -- shop api "$D64" >/dev/null 2>&1 || true
check "…and the environment wins over the file" grep -q '^token=from-environment ' "$GH_LOG"
printf 'KATAP_GH_TOKEN=first\nKATAP_GH_TOKEN=  last-one  \n' > "$K/katap.env"
vdeploy KATAP_GH_TOKEN= -- shop api "$D64" >/dev/null 2>&1 || true
check "the last line for a key wins, its surrounding whitespace removed" grep -q '^token=last-one ' "$GH_LOG"
check "the systemd units do not load the settings file (the token stays out of their environment)" \
    bash -c "! grep -q 'EnvironmentFile' '$REPO'/host/systemd/*.service"
# shellcheck disable=SC2016 # the literal text is what must never run
printf 'KATAP_GH_TOKEN=$(touch %s/executed)\nKATAP_GH=/bin/false\n' "$WORK" > "$K/katap.env"
vdeploy KATAP_GH_TOKEN= -- shop api "$D64" >/dev/null 2>&1 || true
check "the settings file is read as data, never run" test ! -e "$WORK/executed"
# shellcheck disable=SC2016 # the literal text is what must have been passed on
check "…and only its own keys are taken from it (gh was still the stub)" grep -qF 'token=$(touch' "$GH_LOG"
rm -f "$K/katap.env"
set_conf shop api provenance none
out="$(vdeploy -- shop api "$D64" 2>&1 || true)"
check "provenance=none deploys without verification, and says so" \
    bash -c "[ ! -s '$GH_LOG' ] && [ -s '$WORK/pulls' ] && grep -q 'provenance=none' <<<'$out'"
set_conf shop api provenance attested
: > "$WORK/pulls"

# --- ssh-dispatch ---------------------------------------------------------------

section "katap ssh-dispatch"

cat > "$WORK/self-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/dispatched"
EOF
chmod +x "$WORK/self-recorder"
cat > "$STUBS/logger" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/syslog"
EOF
chmod +x "$STUBS/logger"
# dispatch <request> [environment] [project] [components]: the last three are the
# key's forced command.
dispatch() {
    rm -f "$WORK/dispatched"
    SSH_ORIGINAL_COMMAND="$1" SSH_CONNECTION='203.0.113.7 50000 10.0.0.1 22' PATH="$STUBS:$PATH" \
        KATAP_SELF="$WORK/self-recorder" katap ssh-dispatch "${2-production}" "${3-shop}" "${4-api}"
}

: > "$WORK/syslog"
if dispatch "deploy shop api $D64 migrate=$D64" \
    && [ "$(cat "$WORK/dispatched")" = "$(printf '%s\n' deploy shop api "$D64" "migrate=$D64" env=production)" ]; then
    ok "deploy is handed over word by word, with the key's environment appended"
else
    not_ok "deploy is handed over word by word" "$(cat "$WORK/dispatched" 2>/dev/null)"
fi
check "the audit line names the key's binding and the client" \
    grep -qF "ssh-dispatch env=production key=shop/api client=203.0.113.7: deploy shop api" "$WORK/syslog"
if dispatch 'rollback shop api' && [ "$(head -n1 "$WORK/dispatched")" = rollback ]; then
    ok "rollback is handed over"
else
    not_ok "rollback is handed over"
fi
if dispatch "deploy shop web $D64" production shop api,web && [ "$(sed -n 3p "$WORK/dispatched")" = web ]; then
    ok "a key bound to several components deploys each of them"
else
    not_ok "a key bound to several components deploys each of them"
fi
rm -f "$WORK/dispatched"
# shellcheck disable=SC2016 # literal shell syntax is the input under test
for request in 'deploy shop api x; rm -rf /' 'deploy $(id)' 'deploy `id`' 'deploy shop api x | sh' 'deploy shop api x && id' "deploy shop api x"$'\n'"id"; do
    refuses "ssh-dispatch refuses: $(printf '%q' "$request")" "characters outside the allowed set" dispatch "$request"
done
for request in 'run shop api-artisan tinker' 'restore shop api /tmp/x --confirm shop' 'secrets shop api' 'edge up' 'apply' 'release-info' 'add shop spa x' 'bash' ''; do
    refuses "ssh-dispatch refuses the verb in '$request'" "refused" dispatch "$request"
done
refuses "a key without an environment is refused" "this key has no environment" dispatch "deploy shop api $D64" ''
refuses "a key without a project is refused (an old environment-only line)" "names no project and component" dispatch "deploy shop api $D64" production '' ''
refuses "a key without a component is refused" "names no project and component" dispatch "deploy shop api $D64" production shop ''
refuses "a key for one project cannot deploy another" "deploys project 'shop' only" dispatch "deploy blog api $D64"
refuses "…nor roll another back" "deploys project 'shop' only" dispatch "rollback blog api"
refuses "a key for one component cannot deploy another in its project" "deploys shop/{api} only" dispatch "deploy shop web $D64"
refuses "…nor a component whose name is part of its binding" "deploys shop/{api,web} only" dispatch "deploy shop ap $D64" production shop api,web
refuses "…nor the binding's list itself" "characters outside the allowed set" dispatch "deploy shop api,web $D64" production shop api,web
refuses "a project whose name begins the key's is another project" "deploys project 'shop' only" dispatch "deploy sho api $D64"
refuses "…nor roll it back" "deploys shop/{api} only" dispatch "rollback shop web"
refuses "a request cannot choose its environment" "the environment is the key's" dispatch "deploy shop api $D64 env=staging"
refuses "a request cannot carry anything else" "unexpected word" dispatch "deploy shop api $D64 project=blog"
refuses "the old katap=<commit> word is refused with its cause" "no longer part of a request" dispatch "deploy shop api $D64 katap=$SHA40"
mkdir -p "$K/srv/state/.dispatch/shop"
exec 6>"$K/srv/state/.dispatch/shop/.api.lock"
flock 6
refuses "a second dispatch for the same component while one runs is refused" "already running" dispatch "deploy shop api $D64"
exec 6>&-
dispatch "deploy shop api $D64" >/dev/null 2>&1
refuses "a dispatch within the cooldown after the last one is refused" "less than 60s ago" \
    env KATAP_DISPATCH_COOLDOWN=60 bash -c "$(declare -f dispatch katap); K='$K' WORK='$WORK' STUBS='$STUBS'; dispatch 'deploy shop api $D64'"
refuses "a cooldown that is not whole seconds is refused, never ignored" "must be whole seconds" \
    env KATAP_DISPATCH_COOLDOWN=1m bash -c "$(declare -f dispatch katap); K='$K' WORK='$WORK' STUBS='$STUBS'; dispatch 'deploy shop api $D64'"
refuses "…nor one too large to compare" "must be whole seconds" \
    env KATAP_DISPATCH_COOLDOWN=99999999999999999999 bash -c "$(declare -f dispatch katap); K='$K' WORK='$WORK' STUBS='$STUBS'; dispatch 'deploy shop api $D64'"
check "nothing refused was handed over" test ! -e "$WORK/dispatched"

# --- smoke check ----------------------------------------------------------------

section "lib/smoke-check.sh (ported from laravel-api SmokeCheckScriptFeatureTest)"

port=18$((RANDOM % 900 + 100))
python3 "$REPO/tests/stub_server.py" "$port" &
stub_pid=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$port/ready" >/dev/null && break; sleep 0.1; done
base="http://127.0.0.1:$port"
smoke() { SMOKE_ATTEMPTS="${SMOKE_ATTEMPTS:-2}" SMOKE_INTERVAL_SECONDS=0 SMOKE_CONNECT_TIMEOUT_SECONDS=1 SMOKE_MAX_TIME_SECONDS="${SMOKE_MAX_TIME_SECONDS:-2}" sh "$REPO/lib/smoke-check.sh" "$@"; }

check "200 with the expected body passes" smoke "$base/ready" '"status":"ready"'
check "200 passes when no body is expected" smoke "$base/plain"
# A client error ends the check at once ("answered HTTP …"); a server error, a
# connection failure and a wrong body are retried ("after 2 attempt(s)").
refuses "a redirect is never followed, and fails at once" "answered HTTP 302" smoke "$base/redirect"
refuses "404 fails at once" "answered HTTP 404" smoke "$base/not-found"
refuses "401 fails at once" "answered HTTP 401" smoke "$base/unauthorized"
refuses "500 is retried, then fails" "after 2 attempt(s): last result HTTP 500" smoke "$base/server-error"
refuses "503 is retried, then fails" "after 2 attempt(s): last result HTTP 503" smoke "$base/unavailable"
refuses "200 with another body is retried, then fails" "after 2 attempt(s): last result HTTP 200 with an unexpected body" smoke "$base/not-ready" '"status":"ready"'
refuses "a hung server is cut off by the total timeout" "after 1 attempt(s): last result HTTP 000" \
    env SMOKE_ATTEMPTS=1 SMOKE_MAX_TIME_SECONDS=1 SMOKE_CONNECT_TIMEOUT_SECONDS=1 sh "$REPO/lib/smoke-check.sh" "$base/slow" '"status":"ready"'
refuses "a connection failure is retried, then fails" "after 2 attempt(s): last result HTTP 000" smoke "http://127.0.0.1:1/"
refuses "a missing URL fails" "no URL was given" smoke ''
started=$SECONDS
refuses "a client error fails at once, without retrying" "HTTP 404" \
    env SMOKE_ATTEMPTS=30 SMOKE_INTERVAL_SECONDS=5 sh "$REPO/lib/smoke-check.sh" "$base/not-found"
check "…in well under one retry interval" test $((SECONDS - started)) -lt 5
kill "$stub_pid" 2>/dev/null || true

# --- contract rules added after review ------------------------------------------

section "katap check: more of the contract"

mutate "an added Linux capability" "adds Linux capabilities" '
import sys; p = sys.argv[1] + "/web.yml"; s = open(p).read()
open(p, "w").write(s.replace("    mem_limit: 128m\n", "    mem_limit: 128m\n    cap_add: [NET_ADMIN]\n", 1))'
mutate "another external network" "an external network other than katap-edge" '
import sys; p = sys.argv[1] + "/web.yml"; s = open(p).read()
s = s.replace("      default: {}\n", "      default: {}\n      blog_default: {}\n", 1)
open(p, "w").write(s + "  blog_default:\n    external: true\n    name: blog_default\n")'
mutate "a bare reverse_proxy in site.caddy" "a bare reverse_proxy" '
import sys; p = sys.argv[1] + "/site.caddy"; s = open(p).read()
open(p, "w").write(s + "\nevil.test {\n\treverse_proxy bad-api:80\n}\n")'
mutate "a host system path bind-mounted" "bind-mounts a host system path" '
import sys; p = sys.argv[1] + "/web.yml"; s = open(p).read()
open(p, "w").write(s.replace("    mem_limit: 128m\n", "    mem_limit: 128m\n    volumes:\n      - /etc:/host-etc:ro\n", 1))'
mutate "an unknown environment" "environment= must be production or staging" '
import sys; p = sys.argv[1] + "/api.conf"; s = open(p).read()
open(p, "w").write(s.replace("environment=production", "environment=qa"))'
rm -rf "$K/srv/projects/bad"
redis_env_files() { awk '/^  __C__-redis:/{on=1; next} on && /^  [^ ]/{on=0} on && /env/' "$1" | grep -oE '__C__\.[a-z.]*env'; }
check "the Redis services read only their own secrets file" \
    test "$(redis_env_files "$REPO/templates/laravel-api.yml") $(redis_env_files "$REPO/templates/nestjs-api.yml")" = "__C__.redis.env __C__.redis.env"
check "the database health check uses TCP" \
    bash -c "jq -r '.services[\"api-db\"].healthcheck.test | join(\" \")' <<<'$(jq -c . <<<"$shop_config")' | grep -q -- '-h 127.0.0.1'"

# --- katap apply ----------------------------------------------------------------

section "katap apply (projects from katap.json)"

K_MAIN="$K"
K="$(new_katap)"
projects_json() { printf '%s\n' "$1" > "$K/srv/katap.json"; }
tree_sum() { find "$K/srv/projects" "$K/srv/secrets" -type f -exec sha256sum {} + 2>/dev/null | sort; }
# The edge is not running here: apply's reload is recorded, not performed.
applies() { KATAP_DOCKER="$WORK/edge-recorder" katap apply; }
# says <text> <fixed string...>: every string is in the text; lacks: none is.
says() { local text="$1" f; shift; for f in "$@"; do grep -qF -- "$f" <<<"$text" || { echo "missing: $f"; return 1; }; done; }
lacks() { local text="$1" f; shift; for f in "$@"; do ! grep -qF -- "$f" <<<"$text" || { echo "present: $f"; return 1; }; done; }

refuses "apply without katap.json names the file to write" "no $K/srv/katap.json" applies
SHOP_JSON='{
  "host": "203.0.113.10",
  "projects": {
    "shop": {
      "api": { "type": "laravel-api", "repo": "Acme/Shop-API", "domains": ["api.shop.test"] },
      "web": { "type": "spa", "repo": "acme/shop-web", "domains": ["shop.test", "www.shop.test"] }
    },
    "blog": {
      "api": { "type": "nestjs-api", "repo": "acme/blog-api", "domains": ["api.blog.test"] }
    }
  }
}'
projects_json "$SHOP_JSON"
tool_sum() { (cd "$K" && find . -path ./srv -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }
tool_before="$(tool_sum)"
: > "$WORK/edge.log"
if apply_out="$(applies 2>&1)"; then ok "apply creates every declared component"; else not_ok "apply creates every declared component" "$apply_out"; fi
check "…derives the image (lowercase) and keeps the repository as written" \
    bash -c "grep -qxF image=ghcr.io/acme/shop-api '$K/srv/projects/shop/api.conf' && grep -qxF source_repo=Acme/Shop-API '$K/srv/projects/shop/api.conf'"
check "…derives a nestjs-api's migrate image" grep -qxF image_migrate=ghcr.io/acme/blog-api-migrate "$K/srv/projects/blog/api.conf"
check "…and gives a spa no migrate image" bash -c "! grep -q '^image_migrate=' '$K/srv/projects/shop/web.conf'"
check "…and writes nothing into the tool" test "$tool_before" = "$(tool_sum)"
check "…and gives a second project the usual modes, not the secrets' strict ones" \
    bash -c "[ \"\$(stat -c %a '$K/srv/projects/blog')\" = 755 ] && [ \"\$(stat -c %a '$K/srv/projects/blog/api.conf')\" = 644 ] && [ \"\$(stat -c %a '$K/srv/projects/blog/site.caddy')\" = 644 ]"
check "the API's frontend URL and CORS origins come from the project's one web component" \
    bash -c "[ \"\$(grep '^APP_FRONTEND_URL=' '$K/srv/secrets/shop/api.env')\" = APP_FRONTEND_URL=https://shop.test ] && [ \"\$(grep '^CORS_ALLOWED_ORIGINS=' '$K/srv/secrets/shop/api.env')\" = CORS_ALLOWED_ORIGINS=https://shop.test,https://www.shop.test ]"
check "…and stay required in a project without one" \
    bash -c "grep -A1 -xF '# katap:required' '$K/srv/secrets/blog/api.env' | grep -qxF WEB_BASE_URL="
check "apply prints an A record per domain, pointing at the host" grep -qE '^  www\.shop\.test +A  203\.0\.113\.10$' <<<"$apply_out"
check "…the values only the operator knows" says "$apply_out" "shop/api.env: MAIL_MAILER MAIL_FROM_ADDRESS"
check "…and nothing derived" lacks "$apply_out" APP_FRONTEND_URL CORS_ALLOWED_ORIGINS
check "…and the one laptop command, carrying only the host" \
    grep -qxF '  curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/main/connect.sh | bash -s -- root@203.0.113.10' <<<"$apply_out"
check "…and reloads the edge for the new sites" grep -q 'ps -q caddy' "$WORK/edge.log"

# The same component made by hand: apply is a driver over add and secrets, not a
# second way to write a project.
K_APPLY="$K"
K="$(new_katap)"
katap add shop laravel-api api api.shop.test >/dev/null
katap add shop spa web shop.test www.shop.test >/dev/null
check "apply writes the compose files and site.caddy exactly as katap add does" \
    bash -c "cmp '$K/srv/projects/shop/api.yml' '$K_APPLY/srv/projects/shop/api.yml' && cmp '$K/srv/projects/shop/web.yml' '$K_APPLY/srv/projects/shop/web.yml' && cmp '$K/srv/projects/shop/site.caddy' '$K_APPLY/srv/projects/shop/site.caddy'"
check "…and a .conf that differs from add's only in the keys katap.json owns" \
    bash -c "diff <(grep -vE '^(image|image_migrate|source_repo|environment|domains|provenance)=' '$K/srv/projects/shop/api.conf') <(grep -vE '^(image|image_migrate|source_repo|environment|domains|provenance)=' '$K_APPLY/srv/projects/shop/api.conf')"
K="$K_APPLY"

before="$(tree_sum)"
: > "$WORK/edge.log"
again="$(applies 2>&1)"
check "a second apply changes nothing" test "$before" = "$(tree_sum)"
check "…creates nothing" lacks "$again" "Created:"
check "…and still reloads the edge, so a site an interrupted run wrote is served" grep -q 'ps -q caddy' "$WORK/edge.log"

# The operator's own edits survive: only the keys katap.json owns are written.
sed -i 's|^rollout=.*|rollout=api api-worker|; s|^smoke_path=.*|smoke_path=/api/health/live|' "$K/srv/projects/shop/api.conf"
printf '\nshop.test {\n\timport katap_site\n\tredir https://www.shop.test{uri} permanent\n}\n' >> "$K/srv/projects/shop/site.caddy"
site_before="$(sha256sum < "$K/srv/projects/shop/site.caddy")"
projects_json "$(jq '.projects.shop.web.provenance = "none"' <<<"$SHOP_JSON")"
applies >/dev/null 2>&1
check "apply keeps a hand-tuned rollout= and smoke_path=" \
    bash -c "grep -qxF 'rollout=api api-worker' '$K/srv/projects/shop/api.conf' && grep -qxF 'smoke_path=/api/health/live' '$K/srv/projects/shop/api.conf'"
check "…and a hand-added site block" test "$site_before" = "$(sha256sum < "$K/srv/projects/shop/site.caddy")"
check "provenance=none is set from katap.json" grep -qxF provenance=none "$K/srv/projects/shop/web.conf"
check "…with one line per key" test "$(grep -c '^provenance=' "$K/srv/projects/shop/web.conf")" = 1

# A domain change on an existing component: .conf follows, secrets and site.caddy
# are reported, never rewritten.
env_before="$(sha256sum < "$K/srv/secrets/shop/api.env")"
projects_json "$(jq '.projects.shop.web.provenance = "none" | .projects.shop.web.domains = ["shop.test"]' <<<"$SHOP_JSON")"
drift_out="$(applies 2>&1)"
check "a domain change updates the .conf" grep -qxF domains=shop.test "$K/srv/projects/shop/web.conf"
check "…leaves site.caddy and the secrets byte-identical" \
    bash -c "[ '$site_before' = \"\$(sha256sum < '$K/srv/projects/shop/site.caddy')\" ] && [ '$env_before' = \"\$(sha256sum < '$K/srv/secrets/shop/api.env')\" ]"
check "…and says what to change by hand" says "$drift_out" "shop/web: its domains changed; edit" \
    "shop/api: CORS_ALLOWED_ORIGINS is https://shop.test,https://www.shop.test in api.env; the project's frontend now gives https://shop.test."

# Components katap.json does not mention are never touched.
katap add tools spa docs >/dev/null
projects_json "$(jq 'del(.projects.blog) | .projects.shop.web.provenance = "none" | .projects.shop.web.domains = ["shop.test"]' <<<"$SHOP_JSON")"
before="$(tree_sum)"
unmanaged_out="$(applies 2>&1)"
check "a component katap.json drops, or never had, keeps every file" test "$before" = "$(tree_sum)"
check "…and is listed as not managed (dropped)" grep -qxF '  blog/api' <<<"$unmanaged_out"
check "…and is listed as not managed (made by hand)" grep -qxF '  tools/docs' <<<"$unmanaged_out"
GOOD_JSON="$(cat "$K/srv/katap.json")"

# Every value is checked before anything is written.
bad_json() {
    local name="$1" message="$2" filter="$3"
    projects_json "$(jq "$filter" <<<"$GOOD_JSON")"
    before="$(tree_sum)"
    refuses "apply refuses $name" "$message" applies
    [ "$before" = "$(tree_sum)" ] || not_ok "…and wrote nothing after refusing $name"
    projects_json "$GOOD_JSON"
}
bad_json "a newline smuggling a second .conf line" "whitespace or a control character" '.projects.shop.api.repo = "acme/x\nprovenance=none"'
bad_json "a value with a space" "whitespace or a control character" '.projects.shop.api.domains = ["a.test b.test"]'
bad_json "a type that walks out of templates/" "unknown type '../../edge/compose'" '.projects.shop.new = {"type": "../../edge/compose", "repo": "a/b"}'
bad_json "an unknown type" "unknown type 'rails'" '.projects.shop.new = {"type": "rails", "repo": "a/b"}'
bad_json "a repository without an owner" "repo must be owner/name" '.projects.shop.api.repo = "shop-api"'
bad_json "an image with a tag" "image must be a lowercase repository" '.projects.shop.api.image = "ghcr.io/acme/shop-api:latest"'
bad_json "an unknown environment" "environment must be production or staging" '.projects.shop.api.environment = "qa"'
bad_json "an unknown provenance" "provenance must be attested or none" '.projects.shop.api.provenance = "off"'
bad_json "a domain with shell syntax" "whitespace or a control character" '.projects.shop.api.domains = ["x.test;\nrm"]'
bad_json "a wildcard domain (never expanded away by a glob)" "invalid domain '*.shop.test'" '.projects.shop.api.domains = ["*.shop.test"]'
bad_json "a name with a control character" "whitespace or a control character" '.projects["sh\u001fop"] = .projects.shop'
bad_json "one repository for two components in one environment" "a repository deploys one component per environment" '.projects.other = {"api": {"type": "spa", "repo": "acme/SHOP-API", "domains": ["other.test"]}}'
bad_json "a repository named only dots" "repo must be owner/name" '.projects.shop.api.repo = "acme/.."'
bad_json "a type change listed after a component it would rewrite" "never changes type" '.projects.shop.api.provenance = "none" | .projects.shop.web.type = "node-ssr"'
bad_json "a domain another component still serves" "which shop/api still serves" '.projects.shop.api.domains = [] | .projects.other = {"web": {"type": "spa", "repo": "a/b", "domains": ["api.shop.test"]}}'
bad_json "a domain a site.caddy block still serves" "site.caddy already serves" '.projects.other = {"web": {"type": "spa", "repo": "a/b", "domains": ["www.shop.test"]}}'
printf '\nhttps://legacy.shop.test {\n\timport katap_site\n}\nport.shop.test:443 {\n\timport katap_site\n}\n' >> "$K/srv/projects/shop/site.caddy"
bad_json "a domain a hand-written https:// block serves" "site.caddy already serves" '.projects.other = {"web": {"type": "spa", "repo": "a/b", "domains": ["legacy.shop.test"]}}'
bad_json "a domain a hand-written block with a port serves" "site.caddy already serves" '.projects.other = {"web": {"type": "spa", "repo": "a/b", "domains": ["port.shop.test"]}}'
# A component an interrupted run left half-made is named, never silently skipped.
cp "$K/srv/projects/shop/web.yml" "$K/srv/projects/shop/half.yml"
bad_json "a component left with a compose file but no .conf" "shop/half is half-created" '.projects.shop.half = {"type": "spa", "repo": "a/half"}'
rm -f "$K/srv/projects/shop/half.yml"
mkdir -p "$K/srv/secrets/shop" && : > "$K/srv/secrets/shop/half.db.env"
projects_json "$(jq '.projects.shop.half = {"type": "spa", "repo": "a/half"}' <<<"$GOOD_JSON")"
refuses "secrets an interrupted run left half-made are named" "shop/half's secrets are half-made" applies
rm -f "$K/srv/secrets/shop/half.db.env" "$K/srv/projects/shop/half.conf" "$K/srv/projects/shop/half.yml"
projects_json "$GOOD_JSON"
bad_json "an invalid domain" "invalid domain 'x.test;rm'" '.projects.shop.api.domains = ["x.test;rm"]'
bad_json "one domain on two components" "shop.test is claimed by both" '.projects.blog = {"web": {"type": "spa", "repo": "a/b", "domains": ["shop.test"]}}'
katap add tools spa site taken.test >/dev/null
GOOD_JSON="$(cat "$K/srv/katap.json")"
bad_json "a domain a component made by hand already serves" "which tools/site still serves" '.projects.shop.api.domains = ["taken.test"]'
bad_json "a misspelled key" "unknown key(s) domain" '.projects.shop.api.domain = ["x.test"]'
bad_json "a host that is not an IPv4 address" "host must be this server's public IPv4" '.host = "example.com"'
bad_json "an invalid project name" "invalid project name 'Shop'" '.projects.Shop = .projects.shop'
bad_json "a component with a hyphen" "invalid component name 'my-web'" '.projects.shop["my-web"] = .projects.shop.web'
bad_json "a component that changes type" "never changes type" '.projects.shop.web.type = "node-ssr"'
printf '{"projects": ' > "$K/srv/katap.json"
refuses "apply refuses a file that is not JSON" "is not valid JSON" applies
projects_json "$GOOD_JSON"

# A .conf that disagrees with katap.json is never deployed.
# A problem in another project's part of katap.json holds only that project.
projects_json "$(jq '.projects.zed = {"api": {"type": "rails", "repo": "a/z"}}' <<<"$GOOD_JSON")"
check "katap check of one project is not held by a problem in another's part of katap.json" katap check shop
projects_json "$(jq '.projects.shop.web.type = "rails"' <<<"$GOOD_JSON")"
refuses "…while a problem in its own part refuses it" "unknown type 'rails'" katap check shop
printf '{"projects": ' > "$K/srv/katap.json"
refuses "…and so does a file that does not parse" "fix it and run 'katap apply'" katap check shop
projects_json "$GOOD_JSON"
for key in image source_repo environment provenance domains; do
    cp "$K/srv/projects/shop/api.conf" "$WORK/api.conf.before"
    set_conf shop api "$key" "$( [ "$key" = environment ] && echo staging || { [ "$key" = provenance ] && echo none; } || echo changed)"
    refuses "katap check refuses a .conf whose $key was edited away from katap.json" "$key differs from $K/srv/katap.json; run 'katap apply'" katap check shop
    cp "$WORK/api.conf.before" "$K/srv/projects/shop/api.conf"
done
set_conf shop api image ghcr.io/evil/shop-api
applies >/dev/null 2>&1
check "…until apply puts it back" katap check shop
sed -i 's/^api\.shop\.test {$/api.shop.example {/' "$K/srv/projects/shop/site.caddy"
check "katap check warns when a declared domain has no site block" \
    bash -c "KATAP_SRV='$K/srv' KATAP_SETTINGS='$K/katap.env' '$K/bin/katap' check shop 2>&1 | grep -qF \"WARNING: shop/api: 'api.shop.test' is not in\""
sed -i 's/^api\.shop\.example {$/api.shop.test {/' "$K/srv/projects/shop/site.caddy"
# Ownership on the host's shared folder may not stick inside the runner, so this
# directory lives in the container's own /tmp.
OWNED="$(mktemp -d /tmp/katap-owned.XXXXXX)"
cp -a "$K/srv/projects/." "$OWNED/"
chown -R nobody "$OWNED"
check "(the ownership change took effect)" test "$(stat -c %U "$OWNED")" = nobody
refuses "apply refuses to run as anyone but the owner of the projects directory" "run apply as the owner of $OWNED" \
    env KATAP_PROJECTS="$OWNED" KATAP_DOCKER="$WORK/edge-recorder" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "$K/bin/katap" apply
rm -rf "$OWNED"

# release-info: what connect.sh reads.
ssh-keygen -q -t ed25519 -N '' -f "$WORK/serverkey" -C 'root@server' >/dev/null
info() { KATAP_RELEASE_FILE="$WORK/release" KATAP_HOST_KEY_FILE="$WORK/serverkey.pub" katap release-info; }
rm -f "$WORK/release"
refuses "release-info without an installed release refuses" "install Katap with install.sh first" info
git -C "$K" init -q
echo /srv/ > "$K/.git/info/exclude"
git -C "$K" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$K" -c user.email=t@t -c user.name=t commit -qm fixture
printf 'tag=v1.1.0\ncommit=%s\n' "$(git -C "$K" rev-parse HEAD)" > "$WORK/release"
check "release-info prints the release, the host key and every declared component as JSON" \
    bash -c "out=\"\$(KATAP_RELEASE_FILE='$WORK/release' KATAP_HOST_KEY_FILE='$WORK/serverkey.pub' KATAP_SRV='$K/srv' KATAP_SETTINGS='$K/katap.env' '$K/bin/katap' release-info)\" &&
        jq -e --arg c \"\$(git -C '$K' rev-parse HEAD)\" --arg k \"\$(cut -d' ' -f1-2 '$WORK/serverkey.pub')\" '
            .tag == \"v1.1.0\" and .commit == \$c and .host == \"203.0.113.10\" and .hostkey == \$k
            and ([.components[] | \"\(.project)/\(.component)\"] == [\"shop/api\", \"shop/web\"])
            and (.components[0] | .environment == \"production\" and .repo == \"Acme/Shop-API\" and .image == \"ghcr.io/acme/shop-api\" and .domain == \"api.shop.test\" and .smoke_path == \"/api/health/live\")' <<<\"\$out\" >/dev/null"
info > "$WORK/real-release-info.json" 2>/dev/null || true
REAL_INFO_COMMIT="$(git -C "$K" rev-parse HEAD)"
# The deploy user reads root's checkout: git's ownership check must not refuse it.
# A root-owned copy in the container's own /tmp, read as an unprivileged user.
OWNED="$(mktemp -d /tmp/katap-tool.XXXXXX)"
cp -a "$K/." "$OWNED/"
chown -R root:root "$OWNED"
chmod -R go+rX "$OWNED" "$WORK/release" "$WORK/serverkey.pub" "$K/srv/katap.json" "$K/srv/projects"
chmod go+rx "$WORK" "$K" "$K/srv"
chmod 755 "$OWNED"
check "(the tool copy is root's)" test "$(stat -c %U "$OWNED/.git")" = root
check "release-info reads root's tool checkout as another user (the deploy user's view)" \
    setpriv --reuid=nobody --regid=nobody --clear-groups env HOME=/tmp KATAP_RELEASE_FILE="$WORK/release" KATAP_HOST_KEY_FILE="$WORK/serverkey.pub" \
        KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "$OWNED/bin/katap" release-info
rm -rf "$OWNED"
printf 'tag=v1.1.0\ncommit=%s\n' "$(printf 'b%.0s' $(seq 1 40))" > "$WORK/release"
refuses "a tool not at the installed release's commit is refused" "not the release install.sh installed" info
printf 'tag=main\ncommit=%s\n' "$(git -C "$K" rev-parse HEAD)" > "$WORK/release"
refuses "a release file that names no release is refused" "does not name a release" info
printf 'tag=v1.1.0\ncommit=%s\n' "$(git -C "$K" rev-parse HEAD)" > "$WORK/release"
mv "$K/.git" "$K/.git.away"
refuses "release-info refuses a tool that is not a git checkout (its release cannot be proved)" "is not a git checkout" info
mv "$K/.git.away" "$K/.git"
printf 'tag=v1.1.0\ncommit=%s\n' "$(git -C "$K" rev-parse HEAD)" > "$WORK/release"
echo '# local edit' >> "$K/templates/spa.yml"
refuses "release-info refuses a modified tool" "has local modifications" info
git -C "$K" checkout -q -- templates/spa.yml
fill_required shop api
projects_json "$(jq '.projects.shop.api.provenance = "none"' <<<"$GOOD_JSON")"
applies >/dev/null 2>&1
: > "$WORK/pulls"
deploy_out="$(KATAP_RELEASE_FILE="$WORK/release" KATAP_DOCKER="$WORK/docker-recorder" katap deploy shop api "ghcr.io/acme/shop-api@$(digest 1)" 2>&1 || true)"
if [ -s "$WORK/pulls" ]; then ok "a deploy from the installed release's commit goes on to the pull"; else not_ok "a deploy from the installed release's commit goes on to the pull" "$deploy_out"; fi
printf 'tag=v1.1.0\ncommit=%s\n' "$(printf 'b%.0s' $(seq 1 40))" > "$WORK/release"
: > "$WORK/pulls"
refuses "a deploy from any other commit is refused" "not the release install.sh installed" \
    env KATAP_RELEASE_FILE="$WORK/release" KATAP_DOCKER="$WORK/docker-recorder" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "$K/bin/katap" deploy shop api "ghcr.io/acme/shop-api@$(digest 1)"
check "…before anything is pulled" test ! -s "$WORK/pulls"
# Which component is the frontend: one is, two are not.
K_FRONT="$K"
K="$(new_katap)"
projects_json '{"host": "", "projects": {
  "duo":  {"api": {"type": "laravel-api", "repo": "a/duo-api", "domains": ["api.duo.test"]},
           "web": {"type": "spa", "repo": "a/duo-web", "domains": ["duo.test"]},
           "ssr": {"type": "node-ssr", "repo": "a/duo-ssr", "domains": ["app.duo.test"]}},
  "nest": {"api": {"type": "nestjs-api", "repo": "a/nest-api", "domains": ["api.nest.test"]},
           "web": {"type": "spa", "repo": "a/nest-web", "domains": ["nest.test", "www.nest.test"]},
           "docs": {"type": "spa", "repo": "a/nest-docs"}}}}'
applies >/dev/null 2>&1
check "with two web components, the frontend URL stays for the operator" \
    bash -c "grep -A1 -xF '# katap:required' '$K/srv/secrets/duo/api.env' | grep -qxF APP_FRONTEND_URL= && grep -A1 -xF '# katap:required' '$K/srv/secrets/duo/api.env' | grep -qxF CORS_ALLOWED_ORIGINS="
check "a nestjs-api takes its frontend from the one web component with domains" \
    bash -c "grep -qxF WEB_BASE_URL=https://nest.test '$K/srv/secrets/nest/api.env' && grep -qxF CORS_ORIGIN=https://nest.test,https://www.nest.test '$K/srv/secrets/nest/api.env'"
K="$K_FRONT"
K="$K_MAIN"

# --- the Katap action ---------------------------------------------------------------

section "the Katap action (action/deploy.sh, stub docker and ssh)"

check "the action runs no other action (nothing to pin but itself)" bash -c "! grep -qE '^\s*uses:' '$REPO/action.yml'"
check "the example pins the Katap action by commit, never by tag" \
    grep -qE '^\s+uses: jaylordibe/katap@[0-9a-f]{40} ' "$REPO/examples/deploy.yml"
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
# `docker login …` and `docker buildx imagetools inspect <ref> --format …`.
echo "$*" >> "$STUB_DOCKER_LOG"
case "$1" in login) cat >/dev/null; exit 0 ;; esac
[ "$1 $2 $3" = "buildx imagetools inspect" ] || exit 1
case "$4" in
    *-migrate:*) echo '{"digest":"sha256:8888888888888888888888888888888888888888888888888888888888888888"}' ;;
    *) echo '{"digest":"sha256:7777777777777777777777777777777777777777777777777777777777777777"}' ;;
esac
STUB
cat > "$STUBS/ssh" <<'STUB'
#!/usr/bin/env bash
# Records the request (the last argument) and the key file it was given.
key=''
prev=''
for arg in "$@"; do [ "$prev" = -i ] && key="$arg"; prev="$arg"; done
{ echo "key=$key exists=$([ -s "$key" ] && echo yes || echo no)"; echo "request=${*: -1}"; echo "$*"; } > "$SSH_LOG"
STUB
chmod +x "$STUBS/docker" "$STUBS/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey" -C '' >/dev/null
KNOWN="server.test $(cut -d' ' -f1-2 "$WORK/hostkey.pub")"
D7='sha256:7777777777777777777777777777777777777777777777777777777777777777'
D8='sha256:8888888888888888888888888888888888888888888888888888888888888888'
# act [VAR=value...]: runs the action with sensible inputs, overridable.
act() {
    : > "$WORK/stub-docker.log"
    rm -f "$WORK/ssh.log"
    env KATAP_DOCKER="$STUBS/docker" KATAP_SSH="$STUBS/ssh" STUB_DOCKER_LOG="$WORK/stub-docker.log" SSH_LOG="$WORK/ssh.log" \
        KATAP_HOST=server.test KATAP_SSH_KEY="$(cat "$WORK/hostkey")" KATAP_KNOWN_HOSTS="$KNOWN" \
        KATAP_PROJECT=shop KATAP_COMPONENT=api KATAP_IMAGE=ghcr.io/acme/shop-api:main KATAP_REGISTRY_TOKEN=t \
        "$@" bash "$REPO/action/deploy.sh"
}
act >/dev/null 2>&1 || true
check "a tag is resolved to its digest and the request names only that" \
    grep -qxF "request=deploy shop api ghcr.io/acme/shop-api@$D7" "$WORK/ssh.log"
check "the host key is pinned, never accepted on first use" \
    bash -c "grep -q 'StrictHostKeyChecking=yes' '$WORK/ssh.log' && grep -q 'UserKnownHostsFile=' '$WORK/ssh.log' && grep -q 'IdentitiesOnly=yes' '$WORK/ssh.log' && grep -q 'ForwardAgent=no' '$WORK/ssh.log'"
check "the registry token goes in on stdin, never on a command line" \
    bash -c "grep -q -- 'login ghcr.io -u .* --password-stdin' '$WORK/stub-docker.log' && ! grep -qw 't' <(grep -v -- '--password-stdin' '$WORK/stub-docker.log' | tr ' ' '\n')"
check "the key existed for the SSH call and is gone afterwards" \
    bash -c "grep -q 'exists=yes' '$WORK/ssh.log' && [ ! -e \"\$(sed -n 's/^key=\([^ ]*\) .*/\1/p' '$WORK/ssh.log')\" ]"
act KATAP_IMAGE=ghcr.io/acme/blog-api:main KATAP_PROJECT=blog KATAP_MIGRATE_IMAGE=ghcr.io/acme/blog-api-migrate >/dev/null 2>&1 || true
check "a bare migrate repository takes the runtime's tag" \
    grep -qxF "request=deploy blog api ghcr.io/acme/blog-api@$D7 migrate=ghcr.io/acme/blog-api-migrate@$D8" "$WORK/ssh.log"
check "…with one registry login for both" test "$(grep -c '^login ' "$WORK/stub-docker.log")" = 1
check "a digest is passed through without contacting the registry" \
    bash -c "$(declare -f act); STUBS='$STUBS' WORK='$WORK' REPO='$REPO' KNOWN='$KNOWN'
        act KATAP_IMAGE=ghcr.io/acme/shop-api@$D7 >/dev/null && [ ! -s '$WORK/stub-docker.log' ] && grep -qxF 'request=deploy shop api ghcr.io/acme/shop-api@$D7' '$WORK/ssh.log'"
refuses "a foreign registry is refused before it is contacted" "is not on ghcr.io" act KATAP_IMAGE=evil.example/shop-api:main
check "…without a call to that registry, or a login anywhere" test ! -s "$WORK/stub-docker.log"
refuses "a registry that only starts like ghcr.io is refused" "is not on ghcr.io" act KATAP_IMAGE=ghcr.io.evil.example/acme/x:main
check "…without a login anywhere" test ! -s "$WORK/stub-docker.log"
refuses "a foreign migrate registry is refused before any login" "is not on ghcr.io" act KATAP_MIGRATE_IMAGE=evil.example/x-migrate:main
check "…not even to the expected registry" test ! -s "$WORK/stub-docker.log"
refuses "empty known-hosts fails before any connection" "known-hosts is empty or malformed" act KATAP_KNOWN_HOSTS=
check "…and nothing was sent" test ! -e "$WORK/ssh.log"
refuses "a project name with shell syntax is refused" "expected a Katap project name" act 'KATAP_PROJECT=shop;id'
refuses "a migrate tag cannot be derived from a digest" "pass a digest when image is a digest" \
    act KATAP_IMAGE="ghcr.io/acme/blog-api@$D7" KATAP_MIGRATE_IMAGE=ghcr.io/acme/blog-api-migrate

# --- host/provision.sh: the deploy key's line ------------------------------------

section "host/provision.sh authorises a deploy key for one binding"

KEY="$(cat "$WORK/hostkey.pub")"
authorize() { bash -c '. "$1"; KATAP_ROOT=/srv/katap; shift; authorize_ci_key "$@"' _ "$REPO/host/provision.sh" "$@"; }
AK="$WORK/authorized_keys"
rm -f "$AK"
check "a key is written with its forced command and restrict" authorize "$AK" production shop api "$KEY"
check "…exactly once, and bound to environment, project and component" \
    test "$(cat "$AK")" = "restrict,command=\"/srv/katap/bin/katap ssh-dispatch production shop api\" $KEY"
check "provisioning again changes nothing" bash -c "REPO='$REPO'; $(declare -f authorize); authorize '$AK' production shop api '$KEY' >/dev/null && [ \$(wc -l < '$AK') = 1 ]"
refuses "the same key for another binding is refused" "with another restriction or none" authorize "$AK" production blog api "$KEY"
refuses "a project carrying quoting is refused" "--ci-project" authorize "$AK" production 'a" ,no-restrict' api "$KEY"
refuses "a component with a hyphen is refused" "--ci-component" authorize "$AK" production shop my-api "$KEY"
refuses "an unknown environment is refused" "--ci-env production|staging" authorize "$AK" qa shop api "$KEY"
refuses "a key spanning two lines is refused" "single line" authorize "$AK" production shop api "$KEY"$'\n'"$KEY"
refuses "a value that is not a public key is refused" "not an SSH public key" authorize "$AK" production shop api 'command="sh" ssh-ed25519 AAAA'
check "nothing refused was written" test "$(wc -l < "$AK")" = 1

section "host/provision.sh: token, projects file, and the key-only fast path"

prov() { bash -c '. "$1"; shift; "$@"' _ "$REPO/host/provision.sh" "$@"; }
SETTINGS="$WORK/katap.env.test"
printf '# comment\nKATAP_GH_TOKEN=\nKATAP_BACKUP_KEEP=3\nKATAP_GH_TOKEN=\n' > "$SETTINGS"
chmod 640 "$SETTINGS"
TOKEN="github_pat_$(printf 'A%.0s' $(seq 1 40))"
check "a token is written as the one KATAP_GH_TOKEN line" prov write_gh_token "$SETTINGS" "$TOKEN"
check "…in place, keeping every other line and the mode" \
    bash -c "[ \"\$(grep -c '^KATAP_GH_TOKEN=' '$SETTINGS')\" = 1 ] && sed -n 2p '$SETTINGS' | grep -qxF 'KATAP_GH_TOKEN=$TOKEN' && grep -qxF KATAP_BACKUP_KEEP=3 '$SETTINGS' && grep -qxF '# comment' '$SETTINGS' && [ \"\$(stat -c %a '$SETTINGS')\" = 640 ]"
check "…and read back as bin/katap reads it" test "$(prov current_gh_token "$SETTINGS")" = "$TOKEN"
chgrp nobody "$SETTINGS" 2>/dev/null || chgrp nogroup "$SETTINGS"
group_before="$(stat -c %G "$SETTINGS")"
mkdir -p "$WORK/awkspy"
printf '#!/bin/sh\necho "$*" >> "%s/awk-argv"\nexec %s "$@"\n' "$WORK" "$(command -v awk)" > "$WORK/awkspy/awk"
chmod +x "$WORK/awkspy/awk"
rm -f "$WORK/awk-argv"
PATH="$WORK/awkspy:$PATH" prov write_gh_token "$SETTINGS" "$TOKEN" >/dev/null
check "the token never reaches a command line (awk gets it through its environment)" \
    bash -c "[ -s '$WORK/awk-argv' ] && ! grep -q github_pat_ '$WORK/awk-argv'"
check "…the file keeps its group" test "$(stat -c %G "$SETTINGS")" = "$group_before"
check "…and no temporary copy of the token is left" test -z "$(find "$WORK" -maxdepth 1 -name '.katap.env.*')"
cp "$SETTINGS" "$WORK/settings.before"
refuses "a token carrying a newline is refused" "not a fine-grained GitHub token" prov write_gh_token "$SETTINGS" "$TOKEN"$'\n'"KATAP_DISPATCH_COOLDOWN=0"
refuses "a classic token is refused" "not a fine-grained GitHub token" prov write_gh_token "$SETTINGS" "ghp_$(printf 'A%.0s' $(seq 1 36))"
check "…and a refused token changes nothing" cmp "$SETTINGS" "$WORK/settings.before"
rm -f "$WORK/katap.json.test"
check "the projects file is written once, as JSON apply accepts" \
    bash -c ". '$REPO/host/provision.sh'; write_projects_file '$WORK/katap.json.test' && jq -e '.host == \"\" and .projects == {}' '$WORK/katap.json.test' >/dev/null"
echo '{"host": "203.0.113.9", "projects": {}}' > "$WORK/katap.json.test"
check "…and never rewritten" bash -c ". '$REPO/host/provision.sh'; write_projects_file '$WORK/katap.json.test' && grep -q 203.0.113.9 '$WORK/katap.json.test'"
check "--ci-key - takes the key from the first line of standard input" \
    test "$(printf '%s\nsecond line\n' "$KEY" | prov read_ci_key)" = "$KEY"
refuses "…and refuses an empty one" "no key on standard input" bash -c ". '$REPO/host/provision.sh'; read_ci_key </dev/null"
# The fast path, run as the script runs: only --ci-* options authorise the key and
# touch nothing else. Every host command is a recorder that fails if called.
mkdir -p "$WORK/hoststubs"
for cmd in apt-get dpkg-reconfigure systemctl ufw useradd usermod sysctl swapon install-docker; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/host-calls"\nexit 1\n' "$cmd" "$WORK" > "$WORK/hoststubs/$cmd"
    chmod +x "$WORK/hoststubs/$cmd"
done
rm -f "$WORK/host-calls"
FAKE_HOME="$(mktemp -d "$WORK/home.XXXXXX")"
cat > "$WORK/fast-path.sh" <<'EOF'
#!/usr/bin/env bash
# provision.sh's main with the tool at $2, the deploy user's home at $3 (root here).
set -euo pipefail
. "$1"
KATAP_ROOT="$2"
DEPLOY_USER=root
FAKE_HOME="$3"
getent() { echo "root:x:0:0::$FAKE_HOME:/bin/sh"; }
main --ci-key - --ci-env production --ci-project shop --ci-component api
EOF
fast_out="$(printf '%s\n' "$KEY" | PATH="$WORK/hoststubs:$PATH" bash "$WORK/fast-path.sh" "$REPO/host/provision.sh" "$K" "$FAKE_HOME" 2>&1)" && fast_rc=0 || fast_rc=$?
check "provision with only --ci-* options returns success without reaching the host checks" \
    bash -c "[ '$fast_rc' = 0 ] && ! grep -q 'supported on' <<<'$fast_out'"
check "provision with only --ci-* options authorises the key from standard input" \
    grep -qxF "restrict,command=\"$K/bin/katap ssh-dispatch production shop api\" $KEY" "$FAKE_HOME/.ssh/authorized_keys"
check "…and runs no host setup at all" test ! -e "$WORK/host-calls"

# --- install.sh -----------------------------------------------------------------

section "install.sh (a local repository stands in for GitHub)"

ORIGIN="$WORK/origin"
git init -q "$ORIGIN"
gitc() { git -C "$ORIGIN" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$ORIGIN/host"
# Each release's own provision.sh records which release ran it.
release_commit() {
    printf '#!/bin/sh\necho "%s $*" > "%s/provisioned-by-release"\n' "$1" "$WORK" > "$ORIGIN/host/provision.sh"
    chmod +x "$ORIGIN/host/provision.sh"
    echo "$1" > "$ORIGIN/VERSION"
    gitc add -A >/dev/null
    gitc commit -qm "$1"
    gitc tag -a "$1" -m "$1"
}
for v in v1.0.0 v1.1.0 v1.2.0 v2.0.0; do release_commit "$v"; done
# A lightweight tag, as GitHub's "create a new tag" on a release makes.
echo v1.4.0 > "$ORIGIN/VERSION"; gitc commit -qam v1.4.0; gitc tag v1.4.0
API="$WORK/api"
mkdir -p "$API/releases"
latest_is() { printf '{"tag_name": "%s"}\n' "$1" > "$API/releases/latest"; }
cat > "$WORK/provision-recorder" <<EOF
#!/usr/bin/env bash
echo "\$*" > "$WORK/provisioned"
EOF
chmod +x "$WORK/provision-recorder"
INST="$WORK/inst"
installs() {
    rm -f "$WORK/provisioned"
    env KATAP_REPO_URL="$ORIGIN" KATAP_API_URL="file://$API" KATAP_INSTALL_ROOT="$INST/katap" \
        KATAP_RELEASE_FILE="$INST/release" KATAP_PROVISION="$WORK/provision-recorder" bash "$REPO/install.sh" "$@"
}
tag_commit() { git -C "$ORIGIN" rev-parse "$1^{commit}"; }

refuses "no published release is refused, never guessed from tags" "could not reach GitHub" installs
echo '{"message": "Not Found"}' > "$API/releases/latest"
refuses "…and GitHub's 'Not Found' says there is no release" "no published release" installs
check "…and nothing was installed" test ! -e "$INST/katap"
check "--help works when the script is piped" bash -c "bash -s -- --help < '$REPO/install.sh' | grep -q -- '--version vX.Y.Z'"
refuses "--version without a release says so" "--version needs a release" installs --version
latest_is v1.1.0
check "a first install checks out the latest release" installs --harden-ssh
check "…at exactly its tag's commit, detached" \
    bash -c "[ \"\$(git -C '$INST/katap' rev-parse HEAD)\" = '$(tag_commit v1.1.0)' ] && ! git -C '$INST/katap' symbolic-ref -q HEAD"
check "…records the release" test "$(cat "$INST/release")" = "$(printf 'tag=v1.1.0\ncommit=%s' "$(tag_commit v1.1.0)")"
check "…and hands over to that release's provision.sh with the passed options" test "$(cat "$WORK/provisioned")" = --harden-ssh
rm -f "$WORK/provisioned-by-release"
env KATAP_REPO_URL="$ORIGIN" KATAP_API_URL="file://$API" KATAP_INSTALL_ROOT="$INST/katap" KATAP_RELEASE_FILE="$INST/release" \
    bash "$REPO/install.sh" --version v1.1.0 --harden-ssh >/dev/null 2>&1 || true
check "…which is the checked-out release's own host/provision.sh" test "$(cat "$WORK/provisioned-by-release" 2>/dev/null)" = "v1.1.0 --harden-ssh"
check "running it again upgrades to a newer release" installs --version v1.2.0
check "…to its commit" test "$(git -C "$INST/katap" rev-parse HEAD)" = "$(tag_commit v1.2.0)"
before="$(cat "$INST/release")"
echo edited >> "$INST/katap/VERSION"
refuses "a checkout with local changes is never upgraded over" "has local changes" installs --version v1.1.0
git -C "$INST/katap" checkout -q -- VERSION
touch "$INST/katap/planted.service"
refuses "…nor one with an added file" "has local changes" installs --version v1.1.0
rm -f "$INST/katap/planted.service"
check "…and a refusal leaves the release as it was" test "$before" = "$(cat "$INST/release")"
check "…without running provision" test ! -e "$WORK/provisioned"
# unchanged: HEAD and the release record are as they were, and nothing ran.
unchanged() { [ "$(git -C "$INST/katap" rev-parse HEAD)" = "$1" ] && [ "$(cat "$INST/release")" = "$2" ] && [ ! -e "$WORK/provisioned" ]; }
check "a new major version installs like any other (its release notes are the operator's to read)" installs --version v2.0.0
check "going back to an earlier release works the same way" installs --version v1.2.0
check "a lightweight release tag installs at its commit" installs --version v1.4.0
check "…exactly" test "$(git -C "$INST/katap" rev-parse HEAD)" = "$(tag_commit v1.4.0)"
head_before="$(git -C "$INST/katap" rev-parse HEAD)"; rec_before="$(cat "$INST/release")"
refuses "a release older than the installer supports is refused" "older than this installer supports" installs --version v1.0.0
check "…and that refusal changed nothing" unchanged "$head_before" "$rec_before"
refuses "a version that is not vX.Y.Z is refused" "is not a release" installs --version main
refuses "an unknown release is refused" "no release v9.9.9" installs --version v9.9.9
rm -rf "$INST"
mkdir -p "$INST/katap"
touch "$INST/katap/something"
refuses "a /srv/katap that is not a checkout is refused" "is not a Katap checkout" installs --version v1.1.0
rm -rf "$INST"
latest_is v1.1.0
cut_ran=''
lines="$(wc -l < "$REPO/install.sh")"
for n in $(seq 1 "$((lines - 1))"); do
    head -n "$n" "$REPO/install.sh" > "$WORK/install-cut.sh"
    env KATAP_REPO_URL="$ORIGIN" KATAP_API_URL="file://$API" KATAP_INSTALL_ROOT="$INST/katap" \
        KATAP_RELEASE_FILE="$INST/release" KATAP_PROVISION="$WORK/provision-recorder" bash "$WORK/install-cut.sh" >/dev/null 2>&1 || true
    if [ -e "$INST" ] || [ -e "$WORK/provisioned" ]; then cut_ran+=" $n"; rm -rf "$INST" "$WORK/provisioned"; fi
done
check "a download cut short at any line runs nothing" test -z "$cut_ran"

# --- connect.sh -----------------------------------------------------------------

section "connect.sh (stub ssh stands in for the server, stub gh for GitHub)"

CN="$WORK/connect"
mkdir -p "$CN/bin" "$CN/tmp"
ssh-keygen -q -t ed25519 -N '' -f "$CN/server-key" -C '' >/dev/null
SERVER_KEY="$(cut -d' ' -f1-2 "$CN/server-key.pub")"
echo "203.0.113.10 $SERVER_KEY" > "$CN/known_hosts"
CN_COMMIT="$(printf 'c%.0s' $(seq 1 40))"
cat > "$CN/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# `ssh -G <target>`: the configuration; otherwise `ssh <options> -- <target> <command…>`.
if [ "$1" = -G ]; then
    printf 'hostname 203.0.113.10\nport 22\nuserknownhostsfile %s\n' "$CN_KNOWN_HOSTS"
    exit 0
fi
while [ "$1" != -- ]; do shift; done
shift 2
echo "$*" >> "$CN_SSH_LOG"
case "$*" in
    *release-info*) cat "$CN_INFO" ;;
    *provision.sh*)
        [ -z "${CN_PROVISION_FAIL:-}" ] || exit 1
        cat >> "$CN_SERVER_KEYS" ;;
    *) exit 1 ;;
esac
STUB
cat > "$CN/bin/gh" <<'STUB'
#!/usr/bin/env bash
# GitHub, as files under $CN_STATE/<owner>/<repo>/: <environment>/<NAME> for each
# secret and variable.
echo "gh $*" >> "$CN_GH_LOG"
case "$1 $2" in
    "auth status") exit 0 ;;
    "variable delete")
        name="$3"; shift 3; env=_repo; repo=''
        while [ "$#" -gt 0 ]; do case "$1" in --env) env="$2"; shift 2 ;; --repo) repo="$2"; shift 2 ;; *) shift ;; esac; done
        rm -f "$CN_STATE/$repo/$env/$name"; exit 0 ;;
    "secret set"|"variable set")
        [ "$1 $2 $3" != "secret set KATAP_SSH_KEY" ] || echo "key $*" >> "$CN_ORDER"
        name="$3"; shift 3; env=_repo; repo=''; body=''; has_body=false
        while [ "$#" -gt 0 ]; do
            case "$1" in --env) env="$2"; shift 2 ;; --repo) repo="$2"; shift 2 ;; --body) body="$2"; has_body=true; shift 2 ;; *) shift ;; esac
        done
        mkdir -p "$CN_STATE/$repo/$env"
        if [ "$has_body" = true ]; then printf '%s\n' "$body" > "$CN_STATE/$repo/$env/$name"; else cat > "$CN_STATE/$repo/$env/$name"; fi
        exit 0 ;;
esac
[ "$1" = api ] || exit 1
shift
method=GET
if [ "$1" = -X ]; then method="$2"; shift 2; fi
path="$1"
case "$method $path" in
    "GET repos/jaylordibe/katap/git/ref/tags/"*)
        if [ -n "${CN_LIGHTWEIGHT:-}" ]; then echo "commit $CN_GITHUB_COMMIT"; else echo "tag 1111111111111111111111111111111111111111"; fi ;;
    "GET repos/jaylordibe/katap/git/tags/"*) echo "$CN_GITHUB_COMMIT" ;;
    "GET repos/"*/environments/*/secrets/KATAP_SSH_KEY)
        [ -z "${CN_SECRETS_403:-}" ] || { echo "HTTP 403: Resource not accessible" >&2; exit 1; }
        r="${path#repos/}"; r="${r%/environments/*}"; e="${path#*/environments/}"; e="${e%/secrets/*}"
        [ -f "$CN_STATE/$r/$e/KATAP_SSH_KEY" ] || { echo "HTTP 404" >&2; exit 1; }
        echo '{"name": "KATAP_SSH_KEY"}' ;;
    "GET repos/"*/environments/*/deployment-branch-policies)
        d="$CN_STATE/${path#repos/}"; d="${d%/environments/*}"; e="${path#*/environments/}"; e="${e%/deployment-branch-policies}"
        sed 's/^/branch:/' "$d/$e/.branches" | sort | tr '\n' ' ' | sed 's/ $//' ;;
    "GET repos/"*/environments/*)
        d="$CN_STATE/${path#repos/}"; d="${d%/environments/*}/${path##*/environments/}"
        if [ -f "$d/.policy" ]; then echo custom; elif [ -d "$d" ]; then echo none; else echo "HTTP 404" >&2; exit 1; fi ;;
    "PUT repos/"*/environments/*)
        d="$CN_STATE/${path#repos/}"; d="${d%/environments/*}/${path##*/environments/}"
        mkdir -p "$d"; cat > "$d/.policy"; echo "environment ${path#repos/}" >> "$CN_ORDER" ;;
    "POST repos/"*/deployment-branch-policies)
        d="$CN_STATE/${path#repos/}"; d="${d%/environments/*}"; e="${path#*/environments/}"; e="${e%/deployment-branch-policies}"
        for arg in "$@"; do case "$arg" in name=*) echo "${arg#name=}" >> "$d/$e/.branches" ;; esac; done ;;
    *) echo "unexpected: $method $path" >&2; exit 1 ;;
esac
STUB
chmod +x "$CN/bin/ssh" "$CN/bin/gh"
connect_info() {
    jq -n --arg commit "${1:-$CN_COMMIT}" --arg hostkey "$SERVER_KEY" '{
        tag: "v1.1.0", commit: $commit, host: "203.0.113.10", hostkey: $hostkey,
        components: [
            {project: "shop", component: "api", environment: "production", repo: "acme/shop-api", image: "ghcr.io/acme/shop-api", image_migrate: "", domain: "api.shop.test", smoke_path: "/api/health/ready"},
            {project: "shop", component: "web", environment: "production", repo: "acme/shop-web", image: "ghcr.io/acme/shop-web", image_migrate: "", domain: "shop.test", smoke_path: "/"},
            {project: "blog", component: "api", environment: "staging", repo: "acme/blog-api", image: "ghcr.io/acme/blog-api", image_migrate: "ghcr.io/acme/blog-api-migrate", domain: "api.blog.test", smoke_path: "/api/health/readiness"}
        ]}'
}
connect_info > "$CN/info.json"
echo y > "$CN/yes"
echo n > "$CN/no"
# connects [VAR=value...] -- <connect.sh args>
connects() {
    local vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    env KATAP_SSH="$CN/bin/ssh" KATAP_GH="$CN/bin/gh" KATAP_TTY="$CN/yes" TMPDIR="$CN/tmp" \
        CN_KNOWN_HOSTS="$CN/known_hosts" CN_INFO="$CN/info.json" CN_SSH_LOG="$CN/ssh.log" CN_SERVER_KEYS="$CN/server-authorized" \
        CN_GH_LOG="$CN/gh.log" CN_STATE="$CN/state" CN_GITHUB_COMMIT="$CN_COMMIT" CN_ORDER="$CN/order" \
        "${vars[@]}" bash "$REPO/connect.sh" "$@"
}
connect_reset() { rm -rf "$CN/state" "$CN/ssh.log" "$CN/gh.log" "$CN/server-authorized" "$CN/order" "$CN/tmp"/*; }
gh_writes() { grep -E '^gh (secret set|variable set|api -X|pr create)' "$CN/gh.log" 2>/dev/null || true; }

connect_reset
if out="$(connects -- root@203.0.113.10 2>&1)"; then ok "connect.sh connects every declared component"; else not_ok "connect.sh connects every declared component" "$out"; fi
check "…authorising one key per component on the server, for that component only" \
    bash -c "[ \"\$(grep -c 'provision.sh --ci-key -' '$CN/ssh.log')\" = 3 ] && grep -qF -- '--ci-env staging --ci-project blog --ci-component api' '$CN/ssh.log'"
check "…whose private half is the one GitHub holds" \
    bash -c "for e in acme/shop-api/production acme/shop-web/production acme/blog-api/staging; do grep -qF \"\$(ssh-keygen -y -f '$CN/state/'\$e/KATAP_SSH_KEY | cut -d' ' -f2)\" '$CN/server-authorized' || exit 1; done"
deploy_names="$(grep -oE '(secrets|vars)\.[A-Z_]+' "$REPO/examples/deploy.yml" | sed 's/^[a-z]*\.//' | sort -u)"
check "…setting exactly the secrets and variables examples/deploy.yml reads" \
    test "$deploy_names" = "$( (ls "$CN/state/acme/blog-api/staging"; ls "$CN/state/acme/blog-api/_repo") | sort -u)"
check "…with the host key the server reported, under the address deploys use" \
    test "$(cat "$CN/state/acme/shop-api/production/KATAP_KNOWN_HOSTS")" = "203.0.113.10 $SERVER_KEY"
check "…and the public URL check from the component's own smoke path" \
    test "$(cat "$CN/state/acme/shop-api/production/KATAP_URL")" = https://api.shop.test/api/health/ready
check "no private key ever appears on a command line" bash -c "! grep -q 'PRIVATE KEY' '$CN/gh.log' '$CN/ssh.log'"
check "…and none is left on this computer" test -z "$(ls -A "$CN/tmp")"
# The printed command: the example at the server's release, its pin filled in.
check "the printed command fetches examples/deploy.yml at the server's release" \
    grep -qF "curl -fsSL https://raw.githubusercontent.com/jaylordibe/katap/$CN_COMMIT/examples/deploy.yml" <<<"$out"
pin_sed="$(sed -n "s/^    | sed '\(.*\)' > \.github\/workflows\/deploy\.yml$/\1/p" <<<"$out")"
sed "$pin_sed" "$REPO/examples/deploy.yml" > "$CN/deploy.yml"
check "…and its sed fills only the pin, with the release's commit and tag" \
    bash -c "diff <(grep -vE 'uses: jaylordibe/katap@' '$REPO/examples/deploy.yml') <(grep -vE 'uses: jaylordibe/katap@' '$CN/deploy.yml') && grep -qE '^\s+uses: jaylordibe/katap@$CN_COMMIT # v1\.1\.0$' '$CN/deploy.yml'"
check "…and opens no pull request" bash -c "! grep -qE '^gh (pr |api -X (PUT|POST) repos/[^ ]*/(contents|git/refs))' '$CN/gh.log'"
val() { cat "$CN/state/$1/$2" 2>/dev/null; }
check "…with each component's own project, component and image" \
    bash -c "[ \"\$($(declare -f val); CN='$CN'; val acme/blog-api/staging KATAP_PROJECT)\" = blog ] && [ \"\$($(declare -f val); CN='$CN'; val acme/blog-api/staging KATAP_COMPONENT)\" = api ] && [ \"\$($(declare -f val); CN='$CN'; val acme/blog-api/staging KATAP_IMAGE)\" = ghcr.io/acme/blog-api ] && [ \"\$($(declare -f val); CN='$CN'; val acme/blog-api/staging KATAP_MIGRATE_IMAGE)\" = ghcr.io/acme/blog-api-migrate ] && [ \"\$($(declare -f val); CN='$CN'; val acme/shop-web/production KATAP_COMPONENT)\" = web ] && [ \"\$($(declare -f val); CN='$CN'; val acme/shop-api/production KATAP_HOST)\" = 203.0.113.10 ] && [ \"\$($(declare -f val); CN='$CN'; val acme/shop-api/_repo PUBLISH_ENABLED)\" = true ]"
check "…no migrate image where the component has none" test ! -e "$CN/state/acme/shop-api/production/KATAP_MIGRATE_IMAGE"
check "each environment is created limited to its branches before its key is set" \
    bash -c "[ \"\$(cat '$CN/state/acme/shop-api/production/.branches')\" = main ] && [ \"\$(sort '$CN/state/acme/blog-api/staging/.branches' | tr '\n' ' ')\" = 'main staging ' ] && grep -q custom_branch_policies '$CN/state/acme/shop-api/production/.policy' && awk '/^environment acme\/shop-api/ { e = NR } /^key .*acme\/shop-api/ { k = NR } END { exit !(e && k && e < k) }' '$CN/order'"

: > "$CN/ssh.log"; : > "$CN/gh.log"
connects -- root@203.0.113.10 >/dev/null 2>&1 || true
check "running it again makes no key and authorises nothing" bash -c "! grep -q 'provision.sh' '$CN/ssh.log' && ! grep -q 'secret set KATAP_SSH_KEY' '$CN/gh.log'"
jq '.components[0].domain = "api2.shop.test"' "$CN/info.json" > "$CN/info2.json"
connects CN_INFO="$CN/info2.json" -- root@203.0.113.10 >/dev/null 2>&1 || true
check "…but brings a connected repository's variables up to date" test "$(val acme/shop-api/production KATAP_URL)" = https://api2.shop.test/api/health/ready

connect_reset
check "a project name limits it to that project" connects -- root@203.0.113.10 blog
check "…and nothing else is connected" bash -c "[ -d '$CN/state/acme/blog-api/staging' ] && [ ! -e '$CN/state/acme/shop-api' ]"

connect_reset
refuses "a declined confirmation changes nothing" "nothing was changed" connects KATAP_TTY="$CN/no" -- root@203.0.113.10
check "…no key was authorised, no GitHub write made" bash -c "! grep -q provision.sh '$CN/ssh.log' && [ -z \"\$($(declare -f gh_writes); CN='$CN'; gh_writes)\" ]"

connect_reset
check "a lightweight release tag is matched by its commit" connects CN_LIGHTWEIGHT=1 -- root@203.0.113.10 blog
connect_reset
mkdir -p "$CN/state/acme/blog-api/staging"
refuses "an existing environment open to every branch gets no key" "must allow deployments from exactly: main staging (it allows none)" connects -- root@203.0.113.10 blog
check "…and nothing was authorised" bash -c "! grep -q provision.sh '$CN/ssh.log'"
connect_reset
refuses "a gh error other than 'not found' stops before any key is made" "check that your gh login administers" connects CN_SECRETS_403=1 -- root@203.0.113.10
check "…and nothing was authorised" bash -c "! grep -q provision.sh '$CN/ssh.log' 2>/dev/null"
connect_reset
mkdir -p "$CN/state/acme/blog-api/staging"
echo custom > "$CN/state/acme/blog-api/staging/.policy"
printf 'main\n*\n' > "$CN/state/acme/blog-api/staging/.branches"
refuses "an existing environment open to more branches than its own gets no key" "must allow deployments from exactly: main staging" connects -- root@203.0.113.10 blog
check "…and nothing was authorised" bash -c "! grep -q provision.sh '$CN/ssh.log' 2>/dev/null"
connect_reset
if [ -s "$WORK/real-release-info.json" ]; then
    jq --arg k "$(cut -d' ' -f1-2 "$WORK/serverkey.pub")" '.hostkey = $k' "$WORK/real-release-info.json" > "$CN/real-info.json"
    echo "203.0.113.10 $(cut -d' ' -f1-2 "$WORK/serverkey.pub")" > "$CN/known_hosts.real"
    check "connect.sh accepts what the server's real release-info prints" \
        connects CN_INFO="$CN/real-info.json" CN_KNOWN_HOSTS="$CN/known_hosts.real" CN_GITHUB_COMMIT="$REAL_INFO_COMMIT" -- root@203.0.113.10
else
    not_ok "connect.sh accepts what the server's real release-info prints" "no release-info output was saved"
fi
connect_reset
refuses "a server release GitHub does not have for that tag is refused" "but GitHub's v1.1.0 is" connects CN_GITHUB_COMMIT="$(printf 'd%.0s' $(seq 1 40))" -- root@203.0.113.10
check "…before any write" test -z "$(gh_writes)"

connect_reset
ssh-keygen -q -t ed25519 -N '' -f "$CN/other-key" -C '' >/dev/null
echo "203.0.113.10 $(cut -d' ' -f1-2 "$CN/other-key.pub")" > "$CN/known_hosts.other"
refuses "a host key this computer does not already trust is refused" "is not in your known_hosts" \
    connects CN_KNOWN_HOSTS="$CN/known_hosts.other" -- root@203.0.113.10
check "…before any write" test -z "$(gh_writes)"

# What a compromised server could send: each is refused before anything is written.
hostile() {
    local name="$1" message="$2" filter="$3"
    connect_reset
    jq "$filter" <<<"$(connect_info)" > "$CN/info.json"
    refuses "connect.sh refuses $name" "$message" connects -- root@203.0.113.10
    if [ -n "$(gh_writes)" ] || grep -q provision.sh "$CN/ssh.log" 2>/dev/null; then not_ok "…and wrote nothing after refusing $name"; fi
}
# shellcheck disable=SC2016 # literal shell syntax is the input under test
hostile "shell syntax in a project" "invalid project name" '.components[0].project = "shop;id"'
# shellcheck disable=SC2016
hostile "a command substitution in a repository" "invalid repository" '.components[0].repo = "acme/$(id)"'
hostile "a newline smuggling a second component" "not a release description" '.components[0].smoke_path = "/x\nblog\u001fapi"'
hostile "a repository outside owner/name" "invalid repository" '.components[0].repo = "../../etc"'
hostile "a migrate image unlike the image" "invalid migrate image" '.components[2].image_migrate = "ghcr.io/evil/x"'
hostile "a host that is not an address" "is not an IPv4 address" '.host = "evil.example"'
hostile "a tag that is not a release" "names no release" '.tag = "main"'
hostile "a host key of another type" "not an ed25519 key" '.hostkey = "ssh-rsa AAAA"'
hostile "a repository named only dots" "invalid repository" '.components[0].repo = "acme/.."'
hostile "an address outside IPv4" "is not an IPv4 address" '.host = "999.1.1.1"'
hostile "one repository twice in one environment" "a repository deploys one component per environment" '.components[1].repo = "acme/shop-api"'
hostile "a smoke path that is not a plain path" "cannot use as a URL" '.components[0].smoke_path = "/x?y"'
connect_info > "$CN/info.json"

connect_reset
refuses "a server that refuses the key stops before GitHub holds it" "the server refused the key" connects CN_PROVISION_FAIL=1 -- root@203.0.113.10
check "…no KATAP_SSH_KEY was set" test -z "$(find "$CN/state" -name KATAP_SSH_KEY 2>/dev/null)"
check "…and the key it made is gone" test -z "$(ls -A "$CN/tmp")"
refuses "an argument that is not user@host is refused" "is not user@host" connects -- 'root@x;id'

# --- deploy refusals that need no image ------------------------------------------

section "katap deploy / rollback / cron / backup with a fake docker"

refuses "a staging key cannot deploy a production component" "this key deploys staging only" \
    vdeploy -- shop api "$D64" env=staging

# The tool must be the release it was cloned at. The fixture's host directory sits
# inside it here, so it is kept out of the repository, as /srv is on a host.
git -C "$K" init -q
echo /srv/ > "$K/.git/info/exclude"
git -C "$K" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$K" -c user.email=t@t -c user.name=t commit -qm fixture
vdeploy -- shop api "$D64" env=production >/dev/null 2>&1 || true
check "a clean tool checkout goes on to the pull" test -s "$WORK/pulls"
echo '# local edit' >> "$K/templates/spa.yml"
refuses "a tool checkout with local modifications is refused" "has local modifications" vdeploy -- shop api "$D64"
check "…before anything is pulled" test ! -s "$WORK/pulls"
# An enclosing repository, as /srv could be: git must never fall back to it when
# the tool's own .git cannot be read.
git -C "$WORK" init -q
echo garbage > "$K/.git/HEAD.tmp"; mv "$K/.git/HEAD" "$K/.git/HEAD.bak"; mv "$K/.git/HEAD.tmp" "$K/.git/HEAD"
refuses "a checkout git cannot read is refused, never checked against an enclosing repository" "could not check" vdeploy -- shop api "$D64"
mv "$K/.git/HEAD.bak" "$K/.git/HEAD"
rm -rf "$WORK/.git"
git -C "$K" checkout -q -- templates/spa.yml
rm -rf "$K/.git"
: > "$WORK/pulls"

cat > "$WORK/fake-docker" <<STUB
#!/usr/bin/env bash
# Records every call; renders compose config with the real docker; fakes the rest.
echo "\$*" >> "$WORK/fake.log"
project=''
prev=''
for arg in "\$@"; do [ "\$prev" = --project-name ] && project="\$arg"; prev="\$arg"; done
case " \$* " in
    *" pull "*) [ "\${FAKE_PULL_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
    *" config --services"*)
        if [ -n "\${FAKE_SLOW_SERVICES:-}" ]; then
            # One line at a time, the wanted service first: what real compose does.
            for svc in \$FAKE_SLOW_SERVICES; do echo "\$svc"; sleep 0.05; done
            exit 0
        fi
        exec docker "\$@" ;;
    *" config "*) exec docker "\$@" ;;
    *" ps -q "*) [ -n "\${FAKE_DB_DOWN:-}" ] || echo fake-container-id ;;
    *" pg_dump "*) [ "\$project" = "\${FAKE_DUMP_FAIL:-}" ] && exit 1; echo PGDMP-fake ;;
esac
exit 0
STUB
chmod +x "$WORK/fake-docker"
fake() { : > "$WORK/fake.log"; KATAP_DOCKER="$WORK/fake-docker" katap "$@"; }

# History: A, B and C deployed; rolled back to B, which is serving.
rel() { printf 'ghcr.io/acme/shop-api@sha256:%064d' "$1"; }
mkdir -p "$K/srv/state/shop"
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) "
    echo "2026-01-03T00:00:00Z deploy api IMAGE_API=$(rel 12) "
    echo "2026-01-04T00:00:00Z rollback api IMAGE_API=$(rel 11) "
} > "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
refuses "a second rollback goes further back, never forward to what was rolled away from" "could not pull $(rel 10)" \
    env FAKE_PULL_FAIL=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api
refuses "a rollback names only a release this host has deployed" "was never deployed here" \
    fake rollback shop api "$(rel 99)"
printf '{"projects": ' > "$K/srv/katap.json"
refuses "a rollback never depends on katap.json (a half-edited one leaves the way back open)" "was never deployed here" \
    fake rollback shop api "$(rel 99)"
refuses "…while a deploy is held until it is fixed" "fix it and run 'katap apply'" fake deploy shop api "$D64"
rm -f "$K/srv/katap.json"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"
refuses "the first release has nothing before it" "no earlier release" fake rollback shop api

echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
set_conf shop api provenance none
fake deploy shop api "$D64" >/dev/null 2>&1 || true
check "a deploy completes with the fake docker" grep -q 'deploy api IMAGE_API=ghcr.io/acme/shop-api@' "$K/srv/state/shop/history"
check "…and does not reload the shared edge" bash -c "! grep -qE 'caddy (reload|validate)|katap-edge' '$WORK/fake.log'"
set_conf shop api provenance attested
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"

check "katap run finds a service whatever line compose prints it on" \
    env FAKE_SLOW_SERVICES="api-scheduler api-redis api-db api-artisan api-migrate api-permissions api-worker api" \
        KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" run shop api-scheduler
: > "$WORK/fake.log"
set_conf shop api provenance none
refuses "a released component whose database is down is not deployed without a dump" "the pre-deploy dump failed" \
    env FAKE_DB_DOWN=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…and no migration ran" bash -c "! grep -q 'run --rm api-migrate' '$WORK/fake.log'"
set_conf shop api provenance attested
check "katap cron runs each scheduler without starting its dependencies" fake cron shop
check "…as 'run --rm --no-deps api-scheduler'" grep -q 'run --rm --no-deps api-scheduler' "$WORK/fake.log"
exec 5>"$K/srv/state/shop/.lock"
flock 5
check "katap cron skips a minute while the project is busy" fake cron shop
check "…and runs nothing" bash -c "! grep -q ' run ' '$WORK/fake.log'"
exec 5>&-

cp -R "$K/srv/projects/shop" "$K/srv/projects/shop2"
mkdir -p "$K/srv/state/shop2"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop2/images.env"
refuses "one project's failed dump fails the nightly run" "the backup of 'shop' failed" \
    env FAKE_DUMP_FAIL=shop KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" backup --all
check "…but every other project is still dumped" test -n "$(find "$K/srv/backups/shop2" -name 'api-*-scheduled.dump')"
check "…with the release it was taken from beside it" \
    bash -c "grep -qxF 'IMAGE_API=$(rel 10)' \"\$(find '$K/srv/backups/shop2' -name 'api-*-scheduled.dump.images')\""
# Newer pre-deploy dumps than any nightly one: with one count across kinds they would
# rotate every nightly dump out.
for t in 1 2 3; do
    touch "$K/srv/backups/shop2/api-29990101T00000${t}Z-predeploy.dump" "$K/srv/backups/shop2/api-29990101T00000${t}Z-predeploy.dump.images"
done
for _ in $(seq 1 3); do KATAP_DOCKER="$WORK/fake-docker" KATAP_BACKUP_KEEP=2 katap backup shop2 >/dev/null 2>&1; sleep 1; done
check "retention keeps KATAP_BACKUP_KEEP nightly dumps however many deploys came after them" \
    test "$(find "$K/srv/backups/shop2" -name 'api-*-scheduled.dump' | wc -l)" -eq 2
check "…and leaves the other kinds alone" \
    test "$(find "$K/srv/backups/shop2" -name 'api-29990101*-predeploy.dump' | wc -l)" -eq 3
rm -rf "$K/srv/projects/shop2" "$K/srv/state/shop2"

# --- ssh-dispatch detaches from the session --------------------------------------

section "katap ssh-dispatch outlives its SSH session"

cat > "$WORK/slow-self" <<STUB
#!/usr/bin/env bash
echo started
sleep 2
touch "$WORK/detached-done"
exit "\${SLOW_EXIT:-0}"
STUB
chmod +x "$WORK/slow-self"
rm -f "$WORK/detached-done" "$K/srv/state/.dispatch/shop"/*.log.status
# `head -n 1` closes the pipe after the first line: the session is gone.
(SSH_ORIGINAL_COMMAND="deploy shop api $D64" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN=0 "$K/bin/katap" ssh-dispatch production shop api | head -n 1 >/dev/null) || true
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
check "the deploy finishes after the session is closed" test -e "$WORK/detached-done"
for _ in $(seq 1 50); do [ -n "$(find "$K/srv/state/.dispatch/shop" -name '*.log.status')" ] && break; sleep 0.1; done
rm -f "$WORK/detached-done"
(SSH_ORIGINAL_COMMAND="deploy shop api $D64" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN=0 "$K/bin/katap" ssh-dispatch production shop api >/dev/null 2>&1 &)
sleep 0.5
refuses "while a dispatched deploy runs, its worker holds the component's lock" "already running" dispatch "deploy shop api $D64"
refuses "…against every key bound to that component" "a dispatch for shop/api is already running" dispatch "deploy shop api $D64" production shop api,web
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
sleep 0.5
# A key bound to two components: one dispatch at a time across both, and the
# cooldown after it covers both.
rm -f "$WORK/detached-done"
(SSH_ORIGINAL_COMMAND="deploy shop api $D64" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN=0 "$K/bin/katap" ssh-dispatch production shop api,web >/dev/null 2>&1 &)
sleep 0.5
refuses "a key bound to two components cannot run the second while the first runs" "dispatch by this key" \
    dispatch "deploy shop web $D64" production shop api,web
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
sleep 0.5
refuses "…nor right after it, within the cooldown" "this key (shop/{api,web}) dispatched less than" \
    env KATAP_DISPATCH_COOLDOWN=60 bash -c "$(declare -f dispatch katap); K='$K' WORK='$WORK' STUBS='$STUBS'; dispatch 'deploy shop web $D64' production shop api,web"
check "the session receives the deploy's exit status" \
    bash -c "SSH_ORIGINAL_COMMAND='deploy shop api $D64' KATAP_SELF='$WORK/slow-self' SLOW_EXIT=3 KATAP_SRV='$K/srv' KATAP_SETTINGS='$K/katap.env' KATAP_DISPATCH_COOLDOWN=0 '$K/bin/katap' ssh-dispatch production shop api >/dev/null 2>&1; [ \$? = 3 ]"
check "each dispatch leaves its log under its project, readable by the deploy user only" \
    test "$(stat -c %a "$(find "$K/srv/state/.dispatch/shop" -name '*-api-*.log' -size +0 | head -n1)")" = 600

# --- edge config ----------------------------------------------------------------

section "edge/Caddyfile validates with real sites"

CADDY_IMAGE="$(grep -E '^\s*image: caddy' "$REPO/edge/compose.yml" | awk '{print $2}')"
mkdir -p "$WORK/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=origin -keyout "$WORK/certs/origin.key" -out "$WORK/certs/origin.pem" 2>/dev/null
cp "$WORK/certs/origin.pem" "$WORK/certs/cf-origin-pull-ca.pem"
for mode in acme cloudflare internal; do
    check "caddy validate, TLS_MODE=$mode, with the shop and blog sites" \
        docker run --rm -e TLS_MODE="$mode" \
            -v "$K/edge/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$K/srv/projects:/etc/caddy/projects:ro" \
            -v "$WORK/certs:/etc/caddy/certs:ro" "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile
done

# The client address is set on the proxied request itself, in Cloudflare mode only.
xff() {
    docker run --rm -e TLS_MODE="$1" -v "$K/edge/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$K/srv/projects:/etc/caddy/projects:ro" \
        -v "$WORK/certs:/etc/caddy/certs:ro" "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null \
        | jq -c '[.. | objects | select(.handler? == "reverse_proxy") | .headers.request.set["X-Forwarded-For"] // null] | unique'
}
check "cloudflare mode: every proxied request carries X-Forwarded-For from CF-Connecting-IP" \
    test "$(xff cloudflare)" = '[["{http.request.header.CF-Connecting-IP}"]]'
check "acme mode: no proxied request takes a client-supplied header as the address" \
    test "$(xff acme)" = '[null]'

# --- End to end -----------------------------------------------------------------

if [ "${E2E:-}" = 1 ]; then
    # shellcheck source=tests/e2e.sh
    . "$REPO/tests/e2e.sh"
fi

# --- Result ---------------------------------------------------------------------

echo
echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '  - %s\n' "${failures[@]}"
    exit 1
fi
