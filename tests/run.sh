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

# A throwaway copy of Katap, so tests never write into this repository's
# projects/, with its own KATAP_SRV.
new_katap() {
    local dir
    dir="$(mktemp -d "$WORK/katap.XXXXXX")"
    cp -R "$REPO/bin" "$REPO/lib" "$REPO/templates" "$REPO/edge" "$REPO/.github" "$dir/"
    mkdir -p "$dir/projects" "$dir/srv"
    echo "$dir"
}

katap() { KATAP_SRV="$K/srv" "$K/bin/katap" "$@"; }

set_conf() { sed -i "s|^$3=.*|$3=$4|" "$K/projects/$1/$2.conf"; }

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
    for c in "$K/projects/$project"/*.conf; do
        c="$(basename "$c" .conf)"
        : > "$fixture/$c.env"
        : > "$fixture/$c.db.env"
        : > "$fixture/$c.redis.env"
    done
    local files=() f
    for f in "$K/projects/$project"/*.yml; do files+=(-f "$f"); done
    KATAP_ROOT="$K" KATAP_PROJECT="$project" KATAP_SECRETS="$fixture" \
        docker compose --project-name "$project" --project-directory "$K/projects/$project" \
        --env-file /dev/null --profile '*' "${files[@]}" config --format json
}

# --- Static ---------------------------------------------------------------------

section "static"

check "shellcheck: every script" shellcheck -x "$REPO/bin/katap" "$REPO"/lib/*.sh "$REPO"/host/*.sh "$REPO"/.github/scripts/*.sh "$REPO/tests/run.sh" "$REPO/tests/e2e.sh"

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
    bash -c "grep -qxF 'api.shop.test {' '$K/projects/shop/site.caddy' && grep -qxF $'\timport katap_proxy shop-api:80' '$K/projects/shop/site.caddy' && grep -qxF 'shop.test, www.shop.test {' '$K/projects/shop/site.caddy' && grep -qxF $'\timport katap_proxy blog-api:3000' '$K/projects/blog/site.caddy'"
check "an internal-only component gets no site" test ! -e "$K/projects/tools/site.caddy"

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
    rm -rf "$K/projects/bad"
    cp -R "$K/projects/shop" "$K/projects/bad"
    python3 - "$K/projects/bad" <<<"$script"
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
rm -rf "$K/projects/bad"

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
sed -i 's/^TLS_MODE=.*/TLS_MODE=cloudflare/' "$K/edge/edge.env"
rm -rf "$K/srv/secrets/blog"
katap secrets blog api >/dev/null
check "nestjs-api trusts Cloudflare headers in Cloudflare mode" \
    test "$(env_get "$K/srv/secrets/blog/api.env" TRUST_CLOUDFLARE_HEADERS)" = true
sed -i 's/^TLS_MODE=.*/TLS_MODE=acme/' "$K/edge/edge.env"

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
refuses "no image repository configured" "set image=" deploy shop api "$D64"
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

# --- ssh-dispatch ---------------------------------------------------------------

section "katap ssh-dispatch"

cat > "$WORK/self-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/dispatched"
EOF
chmod +x "$WORK/self-recorder"
# dispatch <request> [environment]: the environment is the key's forced command.
dispatch() { rm -f "$WORK/dispatched"; SSH_ORIGINAL_COMMAND="$1" KATAP_SELF="$WORK/self-recorder" katap ssh-dispatch "${2-production}"; }

if dispatch "deploy shop api $D64 migrate=$D64 katap=$SHA40" \
    && [ "$(cat "$WORK/dispatched")" = "$(printf '%s\n' deploy shop api "$D64" "migrate=$D64" "katap=$SHA40" env=production)" ]; then
    ok "deploy is handed over word by word, with the key's environment appended"
else
    not_ok "deploy is handed over word by word" "$(cat "$WORK/dispatched" 2>/dev/null)"
fi
if dispatch 'rollback shop api' && [ "$(head -n1 "$WORK/dispatched")" = rollback ]; then
    ok "rollback is handed over"
else
    not_ok "rollback is handed over"
fi
rm -f "$WORK/dispatched"
# shellcheck disable=SC2016 # literal shell syntax is the input under test
for request in 'deploy shop api x; rm -rf /' 'deploy $(id)' 'deploy `id`' 'deploy shop api x | sh' 'deploy shop api x && id' "deploy shop api x"$'\n'"id"; do
    refuses "ssh-dispatch refuses: $(printf '%q' "$request")" "characters outside the allowed set" dispatch "$request"
done
for request in 'run shop api-artisan tinker' 'restore shop api /tmp/x --confirm shop' 'secrets shop api' 'edge up' 'bash' ''; do
    refuses "ssh-dispatch refuses the verb in '$request'" "refused" dispatch "$request"
done
refuses "a key without an environment is refused" "this key has no environment" dispatch "deploy shop api $D64 katap=$SHA40" ''
refuses "a deploy must name the Katap commit it was resolved against" "names the Katap commit" dispatch "deploy shop api $D64"
refuses "a request cannot choose its environment" "the environment is the key's" dispatch "deploy shop api $D64 katap=$SHA40 env=staging"
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
rm -rf "$K/projects/bad"
redis_env_files() { awk '/^  __C__-redis:/{on=1; next} on && /^  [^ ]/{on=0} on && /env/' "$1" | grep -oE '__C__\.[a-z.]*env'; }
check "the Redis services read only their own secrets file" \
    test "$(redis_env_files "$REPO/templates/laravel-api.yml") $(redis_env_files "$REPO/templates/nestjs-api.yml")" = "__C__.redis.env __C__.redis.env"
check "the database health check uses TCP" \
    bash -c "jq -r '.services[\"api-db\"].healthcheck.test | join(\" \")' <<<'$(jq -c . <<<"$shop_config")' | grep -q -- '-h 127.0.0.1'"

# --- the Deploy workflow ----------------------------------------------------------

section "the Deploy workflow's shape"

deploy_yml="$REPO/.github/workflows/deploy.yml"
check "it is started by hand or by workflow_dispatch only (no repository_dispatch)" \
    bash -c "! grep -q 'repository_dispatch' '$deploy_yml'"
# shellcheck disable=SC2016 # the literal workflow text is what is matched
check "one deploy per environment, project and component at a time" \
    grep -qF 'group: deploy-${{ inputs.environment }}-${{ inputs.project }}-${{ inputs.component }}' "$deploy_yml"
check "the SSH key exists only inside the SSH step, removed on exit" \
    bash -c "awk '/- name: Deploy over SSH/,/- name: Public smoke check/' '$deploy_yml' | grep -qF \"trap 'rm -rf \\\"\\\$ssh_dir\\\"' EXIT\""
check "no step after the SSH step can read a key file" \
    bash -c "! awk '/- name: Public smoke check/,0' '$deploy_yml' | grep -qE 'deploy_key|ssh_dir|SSH_KEY'"
# shellcheck disable=SC2016 # the literal workflow text is what is matched
check "the public smoke check runs Katap's smoke check on the resolved URL" \
    grep -qF 'run: sh lib/smoke-check.sh "$SMOKE_URL" "$SMOKE_BODY"' "$deploy_yml"

# --- resolve-release.sh -----------------------------------------------------------

section ".github/scripts/resolve-release.sh (stub gh and docker)"

R="$(new_katap)"
KATAP_SRV="$R/srv" "$R/bin/katap" add shop laravel-api api api.shop.test >/dev/null
KATAP_SRV="$R/srv" "$R/bin/katap" add blog nestjs-api api api.blog.test >/dev/null
KATAP_SRV="$R/srv" "$R/bin/katap" add priv spa web priv.test >/dev/null
KATAP_SRV="$R/srv" "$R/bin/katap" add stg laravel-api api api.stg.shop.test >/dev/null
sed -i -e 's|^image=.*|image=ghcr.io/acme/shop-api|' -e 's|^source_repo=.*|source_repo=acme/shop-api|' \
    -e 's|^environment=.*|environment=staging|' "$R/projects/stg/api.conf"
sed -i -e 's|^image=.*|image=ghcr.io/acme/shop-api|' -e 's|^source_repo=.*|source_repo=acme/shop-api|' "$R/projects/shop/api.conf"
sed -i -e 's|^image=.*|image=ghcr.io/acme/blog-api|' -e 's|^image_migrate=.*|image_migrate=ghcr.io/acme/blog-api-migrate|' \
    -e 's|^source_repo=.*|source_repo=acme/blog-api|' "$R/projects/blog/api.conf"
sed -i -e 's|^image=.*|image=ghcr.io/acme/priv-web|' -e 's|^provenance=.*|provenance=none|' -e 's|^environment=.*|environment=staging|' "$R/projects/priv/web.conf"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
# `docker buildx imagetools inspect <ref> --format …`: a fixed digest per repository.
echo "$*" >> "${STUB_DOCKER_LOG:-/dev/null}"
[ "$1 $2 $3" = "buildx imagetools inspect" ] || exit 1
case "$4" in
    *-migrate:*) echo '{"digest":"sha256:8888888888888888888888888888888888888888888888888888888888888888"}' ;;
    *) echo '{"digest":"sha256:7777777777777777777777777777777777777777777777777777777777777777"}' ;;
esac
STUB
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# `gh attestation verify oci://<subject> … --source-ref <ref> …`: records the call;
# accepts only GH_ACCEPT_REF, and reports GH_COMMIT (GH_MIGRATE_COMMIT for -migrate).
echo "$*" >> "$GH_LOG"
ref=''
prev=''
for arg in "$@"; do [ "$prev" = --source-ref ] && ref="$arg"; prev="$arg"; done
[ "$ref" = "${GH_ACCEPT_REF:-refs/heads/main}" ] || exit 1
commit="${GH_COMMIT:-c0ffee}"
[[ "$3" != *-migrate@* ]] || commit="${GH_MIGRATE_COMMIT:-$commit}"
[ -n "${GH_NO_COMMIT:-}" ] && { echo '[{"verificationResult":{}}]'; exit 0; }
printf '[{"verificationResult":{"signature":{"certificate":{"sourceRepositoryDigest":"%s"}}}}]\n' "$commit"
STUB
chmod +x "$STUBS/docker" "$STUBS/gh"

# resolve <environment> <project> <component> <image> [migrate image] [VAR=value...]
resolve() {
    local environment="$1" project="$2" component="$3" image="$4" migrate="${5:-}"
    shift 5 2>/dev/null || shift $#
    : > "$WORK/gh.log"
    : > "$WORK/out"
    (cd "$R" && env PATH="$STUBS:$PATH" GH_LOG="$WORK/gh.log" STUB_DOCKER_LOG="$WORK/stub-docker.log" GITHUB_OUTPUT="$WORK/out" GITHUB_SHA="$SHA40" \
        ENVIRONMENT="$environment" PROJECT="$project" COMPONENT="$component" IMAGE="$image" MIGRATE_IMAGE="$migrate" "$@" \
        bash .github/scripts/resolve-release.sh)
}
D7='sha256:7777777777777777777777777777777777777777777777777777777777777777'
D8='sha256:8888888888888888888888888888888888888888888888888888888888888888'

check "a tag is resolved to its digest and the request names it" bash -c "
    $(declare -f resolve); R='$R' STUBS='$STUBS' WORK='$WORK' SHA40='$SHA40'
    resolve production shop api ghcr.io/acme/shop-api:main >/dev/null
    grep -qxF 'request=deploy shop api ghcr.io/acme/shop-api@$D7 katap=$SHA40' '$WORK/out'"
check "the smoke URL and body come from the component's .conf" \
    bash -c "grep -qxF 'smoke_url=https://api.shop.test/api/health/ready' '$WORK/out' && grep -qxF 'smoke_body=\"status\":\"ready\"' '$WORK/out'"
refuses "production accepts only a build of main" "no build-provenance attestation" \
    resolve production shop api ghcr.io/acme/shop-api:main '' GH_ACCEPT_REF=refs/heads/staging
check "…and verifies with --source-ref refs/heads/main and nothing else" \
    bash -c "grep -q -- '--source-ref refs/heads/main' '$WORK/gh.log' && ! grep -q 'refs/heads/staging' '$WORK/gh.log'"
check "staging accepts a build of the staging branch" \
    resolve staging stg api ghcr.io/acme/shop-api:staging '' GH_ACCEPT_REF=refs/heads/staging
check "every verification pins the signer workflow and refuses self-hosted runners" \
    bash -c "grep -q -- '--signer-workflow acme/shop-api/.github/workflows/publish-image.yml' '$WORK/gh.log' && grep -q -- '--deny-self-hosted-runners' '$WORK/gh.log'"
refuses "a production component is never deployed to staging" "is a production component; refusing to deploy it to staging" \
    resolve staging shop api ghcr.io/acme/shop-api:main
refuses "a staging component is never deployed to production" "is a staging component; refusing to deploy it to production" \
    resolve production stg api ghcr.io/acme/shop-api:main
refuses "an image without an attestation is refused" "no build-provenance attestation" \
    resolve production shop api ghcr.io/acme/shop-api:main '' GH_ACCEPT_REF=none
refuses "another repository is refused" "is not this component's repository" \
    resolve production shop api "ghcr.io/evil/shop-api@$D7"
refuses "a repository that only starts the same is refused" "is not this component's repository" \
    resolve production shop api "ghcr.io/acme/shop-api-evil@$D7"
: > "$WORK/stub-docker.log"
refuses "a foreign registry is refused before it is contacted" "is not this component's repository" \
    resolve production shop api "evil.example/shop-api:main"
check "…without a call to that registry" bash -c "! grep -q 'evil.example' '$WORK/stub-docker.log'"
refuses "an unknown environment is refused" "unknown environment" resolve qa shop api ghcr.io/acme/shop-api:main
refuses "a migrate image for a component without one is refused" "has no migrate image" \
    resolve production shop api ghcr.io/acme/shop-api:main "ghcr.io/acme/shop-api@$D7"
check "a nestjs-api tag also names its migrate image" bash -c "
    $(declare -f resolve); R='$R' STUBS='$STUBS' WORK='$WORK' SHA40='$SHA40'
    resolve production blog api ghcr.io/acme/blog-api:main >/dev/null
    grep -qxF 'request=deploy blog api ghcr.io/acme/blog-api@$D7 migrate=ghcr.io/acme/blog-api-migrate@$D8 katap=$SHA40' '$WORK/out'"
refuses "a nestjs-api digest needs its migrate digest" "also needs migrate_image" \
    resolve production blog api "ghcr.io/acme/blog-api@$D7"
refuses "runtime and migrate images from different commits are refused" "built from different commits" \
    resolve production blog api ghcr.io/acme/blog-api:main '' GH_MIGRATE_COMMIT=0ther
refuses "a pair that cannot be compared is refused (fails closed)" "cannot be shown to match" \
    resolve production blog api ghcr.io/acme/blog-api:main '' GH_NO_COMMIT=1
check "provenance=none deploys without verification, and says so" bash -c "
    $(declare -f resolve); R='$R' STUBS='$STUBS' WORK='$WORK' SHA40='$SHA40'
    out=\"\$(resolve staging priv web ghcr.io/acme/priv-web:main 2>&1)\" && [ ! -s '$WORK/gh.log' ] && grep -q 'provenance=none' <<<\"\$out\""

# --- deploy refusals that need no image ------------------------------------------

section "katap deploy / rollback / cron / backup with a fake docker"

refuses "a request resolved against another katap commit is refused" "pull /srv/katap first" \
    deploy shop api "$D64" "katap=$SHA40"
refuses "a staging key cannot deploy a production component" "this key deploys staging only" \
    deploy shop api "$D64" env=staging

# The accept path: a clean checkout at exactly the resolved commit goes on to pull.
git -C "$K" init -q
git -C "$K" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$K" -c user.email=t@t -c user.name=t commit -qm fixture
HEAD_SHA="$(git -C "$K" rev-parse HEAD)"
: > "$WORK/pulls"
deploy shop api "$D64" "katap=$HEAD_SHA" env=production >/dev/null 2>&1 || true
check "a request resolved against this exact, clean checkout is accepted (it reaches the pull)" test -s "$WORK/pulls"
touch "$K/projects/shop/uncommitted.yml.bak"
refuses "a checkout with uncommitted project changes is refused" "has uncommitted changes" \
    deploy shop api "$D64" "katap=$HEAD_SHA"
rm -f "$K/projects/shop/uncommitted.yml.bak"
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
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"
refuses "the first release has nothing before it" "no earlier release" fake rollback shop api

check "katap run finds a service whatever line compose prints it on" \
    env FAKE_SLOW_SERVICES="api-scheduler api-redis api-db api-artisan api-migrate api-permissions api-worker api" \
        KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" run shop api-scheduler
: > "$WORK/fake.log"
refuses "a released component whose database is down is not deployed without a dump" "the pre-deploy dump failed" \
    env FAKE_DB_DOWN=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…and no migration ran" bash -c "! grep -q 'run --rm api-migrate' '$WORK/fake.log'"
check "katap cron runs each scheduler without starting its dependencies" fake cron shop
check "…as 'run --rm --no-deps api-scheduler'" grep -q 'run --rm --no-deps api-scheduler' "$WORK/fake.log"
exec 5>"$K/srv/state/shop/.lock"
flock 5
check "katap cron skips a minute while the project is busy" fake cron shop
check "…and runs nothing" bash -c "! grep -q ' run ' '$WORK/fake.log'"
exec 5>&-

cp -R "$K/projects/shop" "$K/projects/shop2"
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
rm -rf "$K/projects/shop2" "$K/srv/state/shop2"

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
rm -f "$WORK/detached-done"
# `head -n 1` closes the pipe after the first line: the session is gone.
(SSH_ORIGINAL_COMMAND="deploy shop api $D64 katap=$SHA40" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" "$K/bin/katap" ssh-dispatch production | head -n 1 >/dev/null) || true
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
check "the deploy finishes after the session is closed" test -e "$WORK/detached-done"
check "the session receives the deploy's exit status" \
    bash -c "SSH_ORIGINAL_COMMAND='deploy shop api $D64 katap=$SHA40' KATAP_SELF='$WORK/slow-self' SLOW_EXIT=3 KATAP_SRV='$K/srv' '$K/bin/katap' ssh-dispatch production >/dev/null 2>&1; [ \$? = 3 ]"
check "each dispatch leaves its log, readable by the deploy user only" \
    test "$(stat -c %a "$(find "$K/srv/state/dispatch" -name '*.log' -size +0 | head -n1)")" = 600

# --- edge config ----------------------------------------------------------------

section "edge/Caddyfile validates with real sites"

CADDY_IMAGE="$(grep -E '^\s*image: caddy' "$REPO/edge/compose.yml" | awk '{print $2}')"
mkdir -p "$WORK/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=origin -keyout "$WORK/certs/origin.key" -out "$WORK/certs/origin.pem" 2>/dev/null
cp "$WORK/certs/origin.pem" "$WORK/certs/cf-origin-pull-ca.pem"
for mode in acme cloudflare internal; do
    check "caddy validate, TLS_MODE=$mode, with the shop and blog sites" \
        docker run --rm -e TLS_MODE="$mode" \
            -v "$K/edge/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$K/projects:/etc/caddy/projects:ro" \
            -v "$WORK/certs:/etc/caddy/certs:ro" "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile
done

# The client address is set on the proxied request itself, in Cloudflare mode only.
xff() {
    docker run --rm -e TLS_MODE="$1" -v "$K/edge/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$K/projects:/etc/caddy/projects:ro" \
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
