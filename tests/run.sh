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

check "shellcheck: every script" shellcheck -x "$REPO/bin/katap" "$REPO"/lib/*.sh "$REPO"/host/*.sh "$REPO"/action/*.sh "$REPO/install.sh" "$REPO/tests/run.sh" "$REPO/tests/e2e.sh"

check "every link and anchor in README.md and docs/ resolves, and every docs reference in the code names a real heading" \
    python3 "$REPO/tests/check_docs.py" "$REPO"
check "laravel-api and nestjs-api never mention Katap (they publish images; how they are deployed is not theirs)" \
    bash -c "for r in laravel-api nestjs-api; do [ ! -d '$REPO/../'\$r ] || ! grep -rIil katap '$REPO/../'\$r --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor || exit 1; done"

check "the action checks the same project and component names as the server" \
    bash -c "for f in '$REPO/action/deploy.sh'; do grep -qF \"\$(sed -n \"s/^PROJECT_RE='\\(.*\\)'\$/\\1/p\" '$REPO/bin/katap' | sed 's/\\\$\$//')\" \"\$f\" && grep -qF \"\$(sed -n \"s/^COMPONENT_RE='\\(.*\\)'\$/\\1/p\" '$REPO/bin/katap' | sed 's/\\\$\$//')\" \"\$f\" || { echo \$f; exit 1; }; done"

check "the action sends the registry login in exactly the form the server accepts" \
    bash -c "for v in REGISTRY_USER_RE JOB_TOKEN_RE; do l=\"\$(grep -E \"^\$v=\" '$REPO/bin/katap')\"; [ -n \"\$l\" ] && [ \"\$l\" = \"\$(grep -E \"^\$v=\" '$REPO/action/deploy.sh')\" ] || { echo \$v; exit 1; }; done"

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
check "outside Cloudflare mode the edge removes Cloudflare's client-address headers" \
    bash -c "for m in acme internal; do awk -v m=\"(client_ip_\$m) {\" '\$0 == m { on = 1; next } on && /^}/ { exit } on' '$REPO/edge/Caddyfile' | grep -qxF \$'\\theader_up -CF-Connecting-IP' || exit 1; done"
check "Cloudflare mode requires the origin-pull client certificate and Cloudflare's ranges" \
    bash -c "grep -qF 'mode require_and_verify' '$REPO/edge/Caddyfile' && grep -qF '@katap_not_cloudflare not remote_ip 173.245.48.0/20' '$REPO/edge/Caddyfile'"
check "the vendored Cloudflare origin-pull CA is that CA, and is not about to expire" \
    bash -c "openssl x509 -in '$REPO/edge/cloudflare-origin-pull-ca.pem' -noout -subject | grep -qE 'CN ?= ?origin-pull\.cloudflare\.net' && openssl x509 -in '$REPO/edge/cloudflare-origin-pull-ca.pem' -noout -checkend \$((90 * 24 * 3600))"
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
drops_net_raw() {
    local p
    for p in "$@"; do
        rendered "$p" | jq -e '[.services[] | (.cap_drop // []) | index("NET_RAW")] | all' >/dev/null || return 1
    done
}
no_net_raw_warning() { local out; out="$(katap check "$@" 2>&1)" && ! grep -qF 'keep NET_RAW' <<<"$out"; }
check "every template's every service drops NET_RAW (no forged traffic on a shared network)" drops_net_raw shop blog
check "…so katap check has nothing to warn about" no_net_raw_warning shop blog
check "no template's placeholder image can be pulled from anywhere" \
    bash -c "! grep -hoE ':-[^}]+}' '$REPO'/templates/*.yml | grep -vE '^:-registry\.invalid/katap/unreleased@sha256:0{64}}\$'"
cp "$K/srv/projects/shop/api.yml" "$WORK/api.yml.before"
sed -i '/cap_drop: \[NET_RAW\]/d' "$K/srv/projects/shop/api.yml"
check_out="$(katap check shop 2>&1)" && check_rc=0 || check_rc=$?
check "a compose file from an older template that keeps NET_RAW is warned about, naming its services, and still passes" \
    bash -c "[ $check_rc = 0 ] && grep -qF 'keep NET_RAW' <<<\"\$1\" && grep -qE '(^| )api-worker ' <<<\"\$1\"" _ "$check_out"
cp "$WORK/api.yml.before" "$K/srv/projects/shop/api.yml"

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
    [ "$(env_get "$app" TRUSTED_PROXIES)" = "$(grep '^CADDY_IP=' "$K/edge/edge.env" | cut -d= -f2)" ] || { echo "TRUSTED_PROXIES is not the edge's address"; return 1; }
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
# compose stats its working directory, and `sudo -u deploy` keeps the caller's, often
# a home directory deploy cannot read: every compose call must run from /.
cat > "$WORK/pwd-recorder" <<EOF
#!/usr/bin/env bash
echo "\$PWD" >> "$WORK/pwd.log"
EOF
chmod +x "$WORK/pwd-recorder"
: > "$WORK/pwd.log"
(
    cd "$WORK" || exit 1
    KATAP_DOCKER="$WORK/pwd-recorder" katap edge up
    KATAP_DOCKER="$WORK/pwd-recorder" katap check shop
    KATAP_DOCKER="$WORK/pwd-recorder" katap run shop api-artisan
) >/dev/null 2>&1 || true
check "every compose call runs from /, whichever directory katap was started in (edge, check, project)" \
    bash -c "[ \"\$(wc -l < '$WORK/pwd.log')\" -ge 3 ] && ! grep -vx / '$WORK/pwd.log'"
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

# --- images: pulled only when missing, with the deploy's own login ------------------

section "katap deploy pulls only what is missing, with the deploy's own registry login"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
# A docker that knows which images are "present", records every login and pull
# (with the Docker config each one used), and refuses the pull so a deploy stops
# right after it. Everything else goes to the real docker, so the project contract
# is still checked; `compose … run` is refused so no one-shot ever starts.
cat > "$WORK/image-docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    image) [ "\$2" = inspect ] && echo "inspect \$3" >> "$WORK/image.log" && grep -qxF -- "\$3" "$WORK/present"; exit ;;
    login) echo "login config=\${DOCKER_CONFIG:-} args=\$* stdin=\$(cat)" >> "$WORK/image.log"; [ -z "\${FAKE_LOGIN_FAIL:-}" ]; exit ;;
    pull)
        if [ -n "\${DOCKER_CONFIG:-}" ] && [ -d "\$DOCKER_CONFIG" ]; then dir=exists; else dir=none; fi
        echo "pull config=\${DOCKER_CONFIG:-} dir=\$dir args=\$*" >> "$WORK/image.log"
        exit 1 ;;
    compose) for a in "\$@"; do [ "\$a" != run ] || exit 1; done ;;
esac
exec docker "\$@"
EOF
chmod +x "$WORK/image-docker"
TOKEN_GHS="ghs_$(printf 'A%.0s' $(seq 1 36))"
# ideploy [VAR=value...] -- <katap deploy args>
ideploy() {
    local vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    : > "$WORK/image.log"
    env KATAP_DOCKER="$WORK/image-docker" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "${vars[@]}" "$K/bin/katap" deploy "$@"
}
login_file() { printf '%s %s\n' "$1" "$2" > "$WORK/login"; chmod 600 "$WORK/login"; echo "$WORK/login"; }

echo "$D64" > "$WORK/present"
ideploy -- shop api "$D64" >/dev/null 2>&1 || true
check "an image already on this host is never pulled again" bash -c "grep -qxF 'inspect $D64' '$WORK/image.log' && ! grep -q '^pull' '$WORK/image.log' && ! grep -q '^login' '$WORK/image.log'"
: > "$WORK/present"
refuses "a missing image is pulled, and a refused pull changes nothing" "could not pull $D64; nothing was changed" ideploy -- shop api "$D64"
check "…with the deploy user's own login when the deploy brought none" \
    bash -c "grep -q '^pull config= dir=none args=pull --quiet $D64' '$WORK/image.log' && ! grep -q '^login' '$WORK/image.log'"
ideploy KATAP_REGISTRY_FILE="$(login_file octocat "$TOKEN_GHS")" -- shop api "$D64" >/dev/null 2>&1 || true
check "with the deploy's login, ghcr.io is logged in to once, with the token on standard input" \
    bash -c "[ \"\$(grep -c '^login' '$WORK/image.log')\" = 1 ] && grep -q '^login config=[^ ]* args=login ghcr.io --username octocat --password-stdin stdin=$TOKEN_GHS\$' '$WORK/image.log'"
check "…and the pull uses that same throwaway Docker config" \
    bash -c "cfg=\$(sed -n 's/^login config=\([^ ]*\) .*/\1/p' '$WORK/image.log'); [ -n \"\$cfg\" ] && grep -q \"^pull config=\$cfg dir=exists \" '$WORK/image.log'"
check "…which is gone once the deploy ends" \
    bash -c "cfg=\$(sed -n 's/^login config=\([^ ]*\) .*/\1/p' '$WORK/image.log'); [ ! -e \"\$cfg\" ]"
check "the token is never an argument of anything" bash -c "! sed 's/ stdin=.*//' '$WORK/image.log' | grep -qF '$TOKEN_GHS'"
check "the login file is read once and removed" test ! -e "$WORK/login"
refuses "a registry login that fails stops the deploy" "could not log in to ghcr.io" \
    ideploy FAKE_LOGIN_FAIL=1 KATAP_REGISTRY_FILE="$(login_file octocat "$TOKEN_GHS")" -- shop api "$D64"
check "…before any pull" bash -c "! grep -q '^pull' '$WORK/image.log'"
set_conf shop api image registry.example.com/acme/shop-api
ideploy KATAP_REGISTRY_FILE="$(login_file octocat "$TOKEN_GHS")" -- shop api "registry.example.com/acme/shop-api@$(digest 1)" >/dev/null 2>&1 || true
check "an image on another registry never receives the GitHub token" \
    bash -c "! grep -q '^login' '$WORK/image.log' && grep -q '^pull config= ' '$WORK/image.log'"
set_conf shop api image ghcr.io/acme/shop-api

check "the systemd units do not load the settings file" \
    bash -c "! grep -q 'EnvironmentFile' '$REPO'/host/systemd/*.service"
# shellcheck disable=SC2016 # the literal text is what must never run
printf 'KATAP_BACKUP_KEEP=$(touch %s/executed)\nKATAP_DOCKER=/bin/false\n' "$WORK" > "$K/katap.env"
katap help >/dev/null 2>&1 || true
check "the settings file is read as data, never run" test ! -e "$WORK/executed"
printf 'KATAP_RELEASES_KEPT="x"\nKATAP_RELEASES_KEPT= \x27abc\x27 \n' > "$K/katap.env"
kprune() { env KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DOCKER=/bin/true "$@" "$K/bin/katap" images prune; }
refuses "a settings value is unquoted and trimmed, and the last line for a key wins" "(it is 'abc')" kprune
refuses "…and the environment wins over the file" "(it is 'zz')" kprune KATAP_RELEASES_KEPT=zz
refuses "keeping no earlier release is refused: a rollback would need the registry" "at least 1" kprune KATAP_RELEASES_KEPT=0
refuses "a count with a leading zero is refused (it would be read as octal)" "at least 1" kprune KATAP_RELEASES_KEPT=08
rm -f "$K/katap.env"

# --- ssh-dispatch ---------------------------------------------------------------

section "katap ssh-dispatch"

cat > "$WORK/self-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/dispatched"
env > "$WORK/dispatched-env"
if [ -n "\${KATAP_REGISTRY_FILE:-}" ]; then
    cat "\$KATAP_REGISTRY_FILE" > "$WORK/dispatched-login"
    stat -c %a "\$KATAP_REGISTRY_FILE" > "$WORK/dispatched-login-mode"
fi
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
    rm -f "$WORK/dispatched" "$WORK/dispatched-login" "$WORK/dispatched-login-mode"
    SSH_ORIGINAL_COMMAND="$1" SSH_CONNECTION='203.0.113.7 50000 10.0.0.1 22' PATH="$STUBS:$PATH" \
        KATAP_SELF="$WORK/self-recorder" katap ssh-dispatch "${2-production}" "${3-shop}" "${4-api}" < "${STDIN:-/dev/null}"
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
for request in 'run shop api-artisan tinker' 'restore shop api /tmp/x --confirm shop' 'secrets shop api' 'edge up' 'edge cloudflare' 'apply' 'release-info' 'add shop spa x' 'deploy-key shop api' 'remove shop api --confirm shop' 'env shop api' 'images prune' 'bash'; do
    refuses "ssh-dispatch refuses the verb in '$request'" "only 'deploy' and 'rollback'" dispatch "$request"
done
refuses "ssh-dispatch refuses an empty request" "refused" dispatch ''
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
refuses "a token is never a word of the request (the request is logged)" "unexpected word" dispatch "deploy shop api $D64 $TOKEN_GHS"

# The registry login, on standard input.
: > "$WORK/syslog"
printf 'registry octocat %s\n' "$TOKEN_GHS" > "$WORK/stdin-login"
STDIN="$WORK/stdin-login" dispatch "deploy shop api $D64" >/dev/null 2>&1
check "a registry login on standard input reaches the worker, in a file only its owner can read" \
    bash -c "[ \"\$(cat '$WORK/dispatched-login')\" = 'octocat $TOKEN_GHS' ] && [ \"\$(cat '$WORK/dispatched-login-mode')\" = 600 ]"
check "…and that file is gone once the worker ends" bash -c "! ls '$K/srv/state/.dispatch/shop/'.registry.* 2>/dev/null"
check "…and the token is in no argument, no log and no environment" \
    bash -c "! grep -qF '$TOKEN_GHS' '$WORK/dispatched' '$WORK/syslog' '$WORK/dispatched-env' '$K/srv/state/.dispatch/shop/'*.log"
printf 'registry octocat ghp_%s\n' "$(printf 'A%.0s' $(seq 1 36))" > "$WORK/stdin-pat"
STDIN="$WORK/stdin-pat" refuses "a personal access token is refused: only a job's own token, which expires with the job" "must be one line" dispatch "deploy shop api $D64"
printf 'hello\n' > "$WORK/stdin-junk"
STDIN="$WORK/stdin-junk" refuses "anything else on standard input is refused" "must be one line" dispatch "deploy shop api $D64"
printf 'registry octocat %s; id\n' "$TOKEN_GHS" > "$WORK/stdin-inject"
STDIN="$WORK/stdin-inject" refuses "a login carrying anything after the token is refused" "must be one line" dispatch "deploy shop api $D64"
check "no refused login reached a worker" test ! -e "$WORK/dispatched-login"
mkfifo "$WORK/stdin-open"
( exec 3>"$WORK/stdin-open"; sleep 15 ) &
held=$!
started=$SECONDS
STDIN="$WORK/stdin-open" dispatch "deploy shop api $D64" >/dev/null 2>&1 || true
check "a client that never closes its input is cut off after 10 seconds, and the deploy goes ahead without a login" \
    bash -c "[ $((SECONDS - started)) -ge 9 ] && [ $((SECONDS - started)) -lt 15 ] && [ -e '$WORK/dispatched' ] && [ ! -e '$WORK/dispatched-login' ]"
kill "$held" 2>/dev/null || true
wait "$held" 2>/dev/null || true
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
applies() { KATAP_DOCKER="$WORK/edge-recorder" katap apply --yes; }
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
check "…derives the image from the repository, lowercased" grep -qxF image=ghcr.io/acme/shop-api "$K/srv/projects/shop/api.conf"
check "…and shows what it will create before writing anything" says "$apply_out" "katap apply will:" "create shop/api (laravel-api), serving api.shop.test" "create blog/api (nestjs-api)"
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
check "…and what to do next, on this server" says "$apply_out" "katap env <project> <component>" "katap deploy-key <project> <component>"
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
    bash -c "diff <(grep -vE '^(image|image_migrate|environment|domains)=' '$K/srv/projects/shop/api.conf') <(grep -vE '^(image|image_migrate|environment|domains)=' '$K_APPLY/srv/projects/shop/api.conf')"
K="$K_APPLY"

before="$(tree_sum)"
: > "$WORK/edge.log"
again="$(applies 2>&1)"
check "a second apply changes nothing" test "$before" = "$(tree_sum)"
check "apply leaves the mark that katap.json now governs this server's deploys" test -e "$K/srv/state/.applied"
printf 'source_repo=acme/shop-api\nprovenance=attested\n' >> "$K/srv/projects/shop/api.conf"
v1_out="$(applies 2>&1)"
check "apply removes Katap v1's source_repo and provenance from a .conf, and says so" \
    bash -c "! grep -qE '^(source_repo|provenance)=' '$K/srv/projects/shop/api.conf' && grep -qF 'removed v1' <<<\"\$1\"" _ "$v1_out"
printf 'source_repo=acme/shop-api\nprovenance=attested\n' >> "$K/srv/projects/shop/api.conf"
v1_conf="$(sha256sum < "$K/srv/projects/shop/api.conf")"
refuses "…but only once it has shown that and been confirmed: with no terminal and no --yes it refuses" "no terminal to confirm on" \
    env KATAP_DOCKER="$WORK/edge-recorder" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" setsid "$K/bin/katap" apply
check "…naming the change in its preview, and leaving the file as it was" \
    bash -c "[ '$v1_conf' = \"\$(sha256sum < '$K/srv/projects/shop/api.conf')\" ] && grep -qF \"remove v1's source_repo and provenance\" <<<\"\$(env KATAP_DOCKER='$WORK/edge-recorder' KATAP_SRV='$K/srv' KATAP_SETTINGS='$K/katap.env' setsid '$K/bin/katap' apply 2>&1)\""
applies >/dev/null 2>&1
before="$(tree_sum)"
check "…creates nothing" lacks "$again" "Created:"
check "…and has nothing to preview, so asks nothing" lacks "$again" "katap apply will:"
projects_json "$(jq '.projects.shop.extra = {"type": "spa", "repo": "acme/extra"}' <<<"$SHOP_JSON")"
before="$(tree_sum)"
refuses "a change with no terminal to confirm on, and no --yes, is refused" "no terminal to confirm on; nothing was changed" \
    env KATAP_DOCKER="$WORK/edge-recorder" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" setsid "$K/bin/katap" apply
check "…and wrote nothing" test "$before" = "$(tree_sum)"
tty_apply() { printf '%s\n' "$1" | script -qec "env KATAP_DOCKER='$WORK/edge-recorder' KATAP_SRV='$K/srv' KATAP_SETTINGS='$K/katap.env' '$K/bin/katap' apply" /dev/null; }
no_out="$(tty_apply n 2>&1 || true)"
check "on a terminal, apply previews and asks" says "$no_out" "create shop/extra (spa)"
check "…and answering no changes nothing" test "$before" = "$(tree_sum)"
tty_apply y >/dev/null 2>&1 || true
check "…and answering yes creates it" test -f "$K/srv/projects/shop/extra.conf"
rm -f "$K/srv/projects/shop/extra."* "$K/srv/secrets/shop/extra."*
sed -i '/^# extra (spa)$/,$d' "$K/srv/projects/shop/site.caddy"
projects_json "$SHOP_JSON"
check "…and still reloads the edge, so a site an interrupted run wrote is served" grep -q 'ps -q caddy' "$WORK/edge.log"
# A change to a component that exists is previewed and confirmed like a creation:
# image= decides which repository may deploy it.
projects_json "$(jq '.projects.shop.api.image = "ghcr.io/acme/other-api"' <<<"$SHOP_JSON")"
before="$(tree_sum)"
refuses "a change to an existing component with no terminal, and no --yes, is refused" "no terminal to confirm on" \
    env KATAP_DOCKER="$WORK/edge-recorder" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" setsid "$K/bin/katap" apply
no_out="$(tty_apply n 2>&1 || true)"
check "…is previewed, naming the key it changes" says "$no_out" "update shop/api: image"
check "…and answering no changes nothing" test "$before" = "$(tree_sum)"
projects_json "$SHOP_JSON"

# The operator's own edits survive: only the keys katap.json owns are written.
sed -i 's|^rollout=.*|rollout=api api-worker|; s|^smoke_path=.*|smoke_path=/api/health/live|' "$K/srv/projects/shop/api.conf"
printf '\nshop.test {\n\timport katap_site\n\tredir https://www.shop.test{uri} permanent\n}\n' >> "$K/srv/projects/shop/site.caddy"
site_before="$(sha256sum < "$K/srv/projects/shop/site.caddy")"
projects_json "$(jq '.projects.shop.web.environment = "production"' <<<"$SHOP_JSON")"
applies >/dev/null 2>&1
check "apply keeps a hand-tuned rollout= and smoke_path=" \
    bash -c "grep -qxF 'rollout=api api-worker' '$K/srv/projects/shop/api.conf' && grep -qxF 'smoke_path=/api/health/live' '$K/srv/projects/shop/api.conf'"
check "…and a hand-added site block" test "$site_before" = "$(sha256sum < "$K/srv/projects/shop/site.caddy")"
check "…with one line per key it owns" test "$(grep -c '^environment=' "$K/srv/projects/shop/web.conf")" = 1

# A domain change on an existing component: .conf follows, secrets and site.caddy
# are reported, never rewritten.
env_before="$(sha256sum < "$K/srv/secrets/shop/api.env")"
projects_json "$(jq '.projects.shop.web.domains = ["shop.test"]' <<<"$SHOP_JSON")"
drift_out="$(applies 2>&1)"
check "a domain change updates the .conf" grep -qxF domains=shop.test "$K/srv/projects/shop/web.conf"
check "…leaves site.caddy and the secrets byte-identical" \
    bash -c "[ '$site_before' = \"\$(sha256sum < '$K/srv/projects/shop/site.caddy')\" ] && [ '$env_before' = \"\$(sha256sum < '$K/srv/secrets/shop/api.env')\" ]"
check "…and says what to change by hand" says "$drift_out" "shop/web: its domains changed; edit" \
    "shop/api: CORS_ALLOWED_ORIGINS is https://shop.test,https://www.shop.test in api.env; the project's frontend now gives https://shop.test."

# Components katap.json does not mention are never touched.
katap add tools spa docs >/dev/null
projects_json "$(jq 'del(.projects.blog) | .projects.shop.web.domains = ["shop.test"]' <<<"$SHOP_JSON")"
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
bad_json "provenance, a v1 setting, naming that it was removed" "provenance is no longer a setting" '.projects.shop.api.provenance = "none"'
bad_json "a domain with shell syntax" "whitespace or a control character" '.projects.shop.api.domains = ["x.test;\nrm"]'
bad_json "a wildcard domain (never expanded away by a glob)" "invalid domain '*.shop.test'" '.projects.shop.api.domains = ["*.shop.test"]'
bad_json "a name with a control character" "whitespace or a control character" '.projects["sh\u001fop"] = .projects.shop'
bad_json "one repository for two components in one environment" "a repository deploys one component per environment" '.projects.other = {"api": {"type": "spa", "repo": "acme/SHOP-API", "domains": ["other.test"]}}'
bad_json "a repository named only dots" "repo must be owner/name" '.projects.shop.api.repo = "acme/.."'
bad_json "a type change listed after a component it would rewrite" "never changes type" '.projects.shop.api.image = "ghcr.io/acme/other" | .projects.shop.web.type = "node-ssr"'
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
for key in image environment domains; do
    cp "$K/srv/projects/shop/api.conf" "$WORK/api.conf.before"
    set_conf shop api "$key" "$( [ "$key" = environment ] && echo staging || echo changed)"
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

# A deploy runs only the installed release's own commit, unmodified.
git -C "$K" init -q
echo /srv/ > "$K/.git/info/exclude"
git -C "$K" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$K" -c user.email=t@t -c user.name=t commit -qm fixture
printf 'tag=v2.0.0\ncommit=%s\n' "$(git -C "$K" rev-parse HEAD)" > "$WORK/release"
fill_required shop api
projects_json "$GOOD_JSON"
applies >/dev/null 2>&1
: > "$WORK/pulls"
deploy_out="$(KATAP_RELEASE_FILE="$WORK/release" KATAP_DOCKER="$WORK/docker-recorder" katap deploy shop api "ghcr.io/acme/shop-api@$(digest 1)" 2>&1 || true)"
if [ -s "$WORK/pulls" ]; then ok "a deploy from the installed release's commit goes on to the pull"; else not_ok "a deploy from the installed release's commit goes on to the pull" "$deploy_out"; fi
echo '# local edit' >> "$K/templates/spa.yml"
: > "$WORK/pulls"
refuses "a deploy from a modified tool is refused" "has local modifications" \
    env KATAP_RELEASE_FILE="$WORK/release" KATAP_DOCKER="$WORK/docker-recorder" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "$K/bin/katap" deploy shop api "ghcr.io/acme/shop-api@$(digest 1)"
git -C "$K" checkout -q -- templates/spa.yml
printf 'tag=v2.0.0\ncommit=%s\n' "$(printf 'b%.0s' $(seq 1 40))" > "$WORK/release"
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
check "the example workflow pins the Katap action by commit, never by tag" \
    grep -qE '^\s+uses: jaylordibe/katap@[0-9a-f]{40} ' "$REPO/examples/github-workflow.yml"
check "…and gives its deploy jobs no write permission at all" \
    bash -c "[ \"\$(sed -n '/^  deploy:/,\$p' '$REPO/examples/github-workflow.yml' | grep -A1 '^    permissions:' | grep -cxF '      packages: read')\" = 2 ] && ! sed -n '/^  deploy:/,\$p' '$REPO/examples/github-workflow.yml' | grep -qE ': write'"
check "…and deploys only the branch of each environment, only once its variables are set" \
    bash -c "grep -qF \"github.ref == 'refs/heads/main' && vars.KATAP_PROJECT != '' }}\" '$REPO/examples/github-workflow.yml' && grep -qF \"github.ref == 'refs/heads/staging' && vars.KATAP_STAGING_PROJECT != '' }}\" '$REPO/examples/github-workflow.yml'"
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
{ echo "key=$key exists=$([ -s "$key" ] && echo yes || echo no)"; echo "request=${*: -1}"; echo "$*"; echo "stdin=$(cat)"; } > "$SSH_LOG"
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
check "a job token that is not a GitHub Actions token never goes to the server" grep -qxF 'stdin=' "$WORK/ssh.log"
act KATAP_REGISTRY_TOKEN="$TOKEN_GHS" KATAP_REGISTRY_USER=octocat >/dev/null 2>&1 || true
check "the job's own token goes to the server on standard input, for its one pull" grep -qxF "stdin=registry octocat $TOKEN_GHS" "$WORK/ssh.log"
check "…and is in no argument of the SSH call" bash -c "! grep -v '^stdin=' '$WORK/ssh.log' | grep -qF '$TOKEN_GHS'"
sed -n 's/^stdin=//p' "$WORK/ssh.log" > "$WORK/stdin-from-action"
STDIN="$WORK/stdin-from-action" dispatch "deploy shop api $D64" >/dev/null 2>&1 || true
check "the server accepts exactly the login the action sends" \
    bash -c "[ \"\$(cat '$WORK/dispatched-login' 2>/dev/null)\" = 'octocat $TOKEN_GHS' ]"
# Any action of this major version deploys to any server of it: v2.0.0's own
# deploy.sh, run as it was released, is accepted by this dispatcher.
if git -c safe.directory="$REPO" -C "$REPO" cat-file -e v2.0.0:action/deploy.sh 2>/dev/null; then
    mkdir -p "$WORK/action-v2.0.0/action"
    git -c safe.directory="$REPO" -C "$REPO" show v2.0.0:action/deploy.sh > "$WORK/action-v2.0.0/action/deploy.sh"
    rm -f "$WORK/ssh.log"
    env KATAP_DOCKER="$STUBS/docker" KATAP_SSH="$STUBS/ssh" STUB_DOCKER_LOG="$WORK/stub-docker.log" SSH_LOG="$WORK/ssh.log" \
        KATAP_HOST=server.test KATAP_SSH_KEY="$(cat "$WORK/hostkey")" KATAP_KNOWN_HOSTS="$KNOWN" \
        KATAP_PROJECT=shop KATAP_COMPONENT=api KATAP_IMAGE="$D64" KATAP_REGISTRY_TOKEN="$TOKEN_GHS" KATAP_REGISTRY_USER=octocat \
        bash "$WORK/action-v2.0.0/action/deploy.sh" >/dev/null 2>&1 || true
    sed -n 's/^stdin=//p' "$WORK/ssh.log" > "$WORK/stdin-v2.0.0"
    STDIN="$WORK/stdin-v2.0.0" dispatch "$(sed -n 's/^request=//p' "$WORK/ssh.log")" >/dev/null 2>&1 || true
    check "v2.0.0's action is accepted by this server, request and login alike" \
        bash -c "[ \"\$(cat '$WORK/dispatched' 2>/dev/null)\" = \"\$(printf '%s\\n' deploy shop api '$D64' env=production)\" ] && [ \"\$(cat '$WORK/dispatched-login' 2>/dev/null)\" = 'octocat $TOKEN_GHS' ]"
else
    not_ok "v2.0.0's action is accepted by this server" "the v2.0.0 tag is not in this checkout"
fi
act KATAP_REGISTRY_TOKEN="$TOKEN_GHS" KATAP_REGISTRY_USER=octocat_acme >/dev/null 2>&1 || true
check "an Enterprise Managed User's login is sent too" grep -qxF "stdin=registry octocat_acme $TOKEN_GHS" "$WORK/ssh.log"
for user in 'a b' 'x;id' '-x'; do
    act KATAP_REGISTRY_TOKEN="$TOKEN_GHS" KATAP_REGISTRY_USER="$user" >/dev/null 2>&1 || true
    check "a registry user '$user' is never sent" grep -qxF 'stdin=' "$WORK/ssh.log"
done
user_warn="$(act KATAP_REGISTRY_TOKEN="$TOKEN_GHS" KATAP_REGISTRY_USER='a b' 2>&1 || true)"
check "a job token held back for its user name says that, not that the token is wrong" says "$user_warn" "::warning::registry-user 'a b' is not a GitHub user name"
warn_out="$(act 2>&1 || true)"
check "a registry-token that is not this job's token is not sent, and the action says so" \
    says "$warn_out" "::warning::registry-token is not this job's GitHub token"
act KATAP_REGISTRY_TOKEN="$TOKEN_GHS" KATAP_REGISTRY_USER=octocat KATAP_REGISTRY=registry.example.com KATAP_IMAGE="registry.example.com/acme/shop-api@$D7" >/dev/null 2>&1 || true
check "…and never when the image is on another registry" grep -qxF 'stdin=' "$WORK/ssh.log"
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

# --- katap deploy-key --------------------------------------------------------------

section "katap deploy-key makes a key that deploys one component, and nothing else"

K_KEY="$K"
K="$(new_katap)"
projects_json "$SHOP_JSON"
applies >/dev/null 2>&1
AK="$WORK/key-home/.ssh/authorized_keys"
rm -rf "$WORK/key-home"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/serverkey" -C 'root@server' >/dev/null
printf 'tag=v2.0.0\ncommit=%s\n' "$(printf 'c%.0s' $(seq 1 40))" > "$WORK/release"
mkdir -p "$WORK/key-tmp"
dkey() { TMPDIR="$WORK/key-tmp" KATAP_AUTHORIZED_KEYS="$AK" KATAP_HOST_KEY_FILE="$WORK/serverkey.pub" KATAP_RELEASE_FILE="$WORK/release" katap deploy-key "$@"; }
key_out="$(dkey shop api 2>&1)" && key_rc=0 || key_rc=$?
check "a key is made and authorised" test "$key_rc" = 0
check "…bound by its forced command to this component, in its environment, with restrict" \
    bash -c "[ \"\$(wc -l < '$AK')\" = 1 ] && grep -qE '^restrict,command=\"$K/bin/katap ssh-dispatch production shop api\" ssh-ed25519 [A-Za-z0-9+/]+=* katap shop/api production$' '$AK'"
check "…and the file and its folder are its owner's only" \
    bash -c "[ \"\$(stat -c %a '$AK')\" = 600 ] && [ \"\$(stat -c %a '$(dirname "$AK")')\" = 700 ]"
printf '%s\n' "$key_out" | sed -n '/^-----BEGIN OPENSSH PRIVATE KEY-----$/,/^-----END OPENSSH PRIVATE KEY-----$/p' > "$WORK/printed-key"
chmod 600 "$WORK/printed-key"
check "the private key it prints is the one it authorised" \
    bash -c "[ \"\$(ssh-keygen -y -f '$WORK/printed-key' | cut -d' ' -f1-2)\" = \"\$(sed 's/^restrict,command=\"[^\"]*\" //' '$AK' | cut -d' ' -f1-2)\" ]"
check "…and none of it is kept on this host" bash -c "! grep -rlF 'OPENSSH PRIVATE KEY' '$K' '$WORK/key-home' '$WORK/key-tmp' 2>/dev/null"
check "…not even in a temporary directory" bash -c "[ -z \"\$(ls -A '$WORK/key-tmp')\" ]"
check "it prints the other two secrets, from this server's own settings and host key" \
    says "$key_out" KATAP_HOST KATAP_KNOWN_HOSTS "203.0.113.10 $(cut -d' ' -f1-2 "$WORK/serverkey.pub")"
check "…and the two variables naming this component, and the URL checked after a deploy" \
    bash -c "grep -qE '^KATAP_PROJECT +shop\$' <<<\"\$1\" && grep -qE '^KATAP_COMPONENT +api\$' <<<\"\$1\" && grep -qE '^KATAP_URL +https://api.shop.test/api/health/ready\$' <<<\"\$1\"" _ "$key_out"
check "…and which major version the workflow's pin may be" says "$key_out" "This server runs Katap v2.0.0" "may be any v2 release"
# The secrets and variables the example workflow reads are exactly the ones
# deploy-key tells you to add: one list, checked here, never two that drift.
workflow_names() { sed -n "/^  $1:/,/^  [a-z-]*:\$/p" "$REPO/examples/github-workflow.yml" | grep -oE '(secrets|vars)\.KATAP_[A-Z_]+' | sed 's/^[a-z]*\.//' | sort -u; }
printed_names() { grep -oE '^KATAP_[A-Z_]+' <<<"$1" | sort -u; }
check "every secret and variable the example's production deploy job reads is one deploy-key prints, and no other" \
    test "$(workflow_names deploy)" = "$(printed_names "$key_out")"

refuses "a second key for the same component is refused without --replace" "already has a production deploy key" dkey shop api
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOperatorsOwnKeyOperatorsOwnKeyOperatorsOwn admin@laptop' >> "$AK"
first="$(grep ssh-dispatch "$AK")"
dkey shop api --replace >/dev/null 2>&1
check "--replace swaps the key: the old one stops working at once" \
    bash -c "[ \"\$(grep -c ssh-dispatch '$AK')\" = 1 ] && [ \"\$(grep ssh-dispatch '$AK')\" != '$first' ]"
check "…and every line it does not own is kept" grep -qF 'admin@laptop' "$AK"
mkdir -p "$WORK/mktemp-bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/mktemp.log"\nexec %s "$@"\n' "$WORK" "$(command -v mktemp)" > "$WORK/mktemp-bin/mktemp"
chmod +x "$WORK/mktemp-bin/mktemp"
: > "$WORK/mktemp.log"
PATH="$WORK/mktemp-bin:$PATH" dkey shop api --replace >/dev/null 2>&1
check "…rewritten in its own directory, so the rename is atomic and nothing passes through /tmp" \
    bash -c "grep -qxF '$(dirname "$AK")/.authorized_keys.XXXXXX' '$WORK/mktemp.log' && ! ls '$(dirname "$AK")'/.authorized_keys.* 2>/dev/null"
sed -i '/admin@laptop/d' "$AK"
dkey shop web >/dev/null 2>&1
check "another component gets a key of its own, beside the first" test "$(wc -l < "$AK")" = 2
revoke_out="$(dkey shop web --revoke 2>&1)"
check "--revoke withdraws a component's key, and only that one" \
    bash -c "! grep -q 'ssh-dispatch production shop web\"' '$AK' && grep -q 'ssh-dispatch production shop api\"' '$AK'"
check "…and says to delete its secrets from the repository" says "$revoke_out" "no longer works"
refuses "…and says so when there is none to withdraw" "has no production deploy key" dkey shop web --revoke
refuses "--replace and --revoke together are refused" "usage" dkey shop web --replace --revoke
echo 'restrict,command="/srv/katap/bin/katap ssh-dispatch production shop api,web" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIV1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V katap v1' >> "$AK"
revoke_v1="$(dkey shop web --revoke 2>&1 || true)"
check "--revoke never says a key no longer works while a v1 key bound to several components still deploys it" \
    bash -c "grep -qF 'still deploys it' <<<\"\$1\" && ! grep -qF 'no longer works' <<<\"\$1\"" _ "$revoke_v1"
sed -i '/katap v1$/d' "$AK"
dkey shop web >/dev/null 2>&1
echo 'restrict,command="/srv/katap/bin/katap ssh-dispatch production shop api,web" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIV1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V katap v1' >> "$AK"
refuses "--revoke with the component's own key and a v1 key: refused, naming the v1 key" "still deploys it" dkey shop web --revoke
check "…having removed its own key, and left the v1 key for the operator" \
    bash -c "! grep -q 'ssh-dispatch production shop web\"' '$AK' && grep -q 'katap v1\$' '$AK'"
refuses "…whichever place the component has in the v1 key's list" "still deploys it" dkey shop api --revoke
sed -i '/katap v1$/d' "$AK"
dkey shop api >/dev/null 2>&1
dkey shop web >/dev/null 2>&1
projects_json "$(jq '.projects.blog.api.environment = "staging"' <<<"$SHOP_JSON")"
applies >/dev/null 2>&1
stg_out="$(dkey blog api 2>&1 || true)"
check "a staging key is bound to staging" grep -qF 'ssh-dispatch staging blog api"' "$AK"
check "…and its secrets and variables named so they never collide with production's" \
    says "$stg_out" KATAP_STAGING_SSH_KEY KATAP_STAGING_HOST KATAP_STAGING_KNOWN_HOSTS KATAP_STAGING_PROJECT KATAP_STAGING_COMPONENT "every push to staging"
check "…exactly the ones the example's staging deploy job reads" \
    test "$(workflow_names deploy-staging)" = "$(printed_names "$stg_out")"
echo 'restrict,command="/srv/katap/bin/katap ssh-dispatch production shop api,web" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIV1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V1V katap v1' >> "$AK"
v1_out="$(dkey shop web --replace 2>&1 || true)"
check "a v1 key bound to several components is named, not silently left deploying" says "$v1_out" "bound to shop/web together with other"
sed -i '/katap v1$/d' "$AK"
refuses "an unknown component is refused" "unknown component" dkey shop nope
if [ "$(id -u)" = 0 ]; then
    chown nobody "$K/srv/projects"
    ak_before="$(cat "$AK")"
    refuses "deploy-key refuses to run as anyone but the owner of the projects (the key would go to the wrong user)" "run deploy-key as the owner" dkey shop api --replace
    check "…and wrote no key" test "$ak_before" = "$(cat "$AK")"
    chown root "$K/srv/projects"
fi
refuses "a project carrying shell syntax is refused" "invalid project name" dkey 'shop;id' api
projects_json "$(jq '.host = ""' <<<"$SHOP_JSON")"
refuses "without the server's address in katap.json it refuses, naming the file" "set host" dkey shop api
projects_json "$SHOP_JSON"
K="$K_KEY"

section "host/provision.sh: the projects file and the katap command"

rm -f "$WORK/katap.json.test"
check "the projects file is written once, as JSON apply accepts" \
    bash -c ". '$REPO/host/provision.sh'; write_projects_file '$WORK/katap.json.test' && jq -e '.host == \"\" and .projects == {}' '$WORK/katap.json.test' >/dev/null"
echo '{"host": "203.0.113.9", "projects": {}}' > "$WORK/katap.json.test"
check "…and never rewritten" bash -c ". '$REPO/host/provision.sh'; write_projects_file '$WORK/katap.json.test' && grep -q 203.0.113.9 '$WORK/katap.json.test'"
check "the host settings ask for no GitHub token" bash -c "! grep -q 'GH_TOKEN' '$REPO/host/provision.sh'"
bash -c ". '$REPO/host/provision.sh'; KATAP_ROOT='$K'; DEPLOY_USER=\"\$(id -un)\"; write_katap_command '$WORK/katap-command'" >/dev/null 2>&1
check "the katap command it writes runs the tool as the deploy user" \
    bash -c "[ \"\$(stat -c %a '$WORK/katap-command')\" = 755 ] && grep -qF \"exec sudo -u '\$(id -un)' -H -- $K/bin/katap\" '$WORK/katap-command'"
check "…and runs it directly when already that user" bash -c "'$WORK/katap-command' help | grep -q 'katap deploy-key'"

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
up_out="$(installs --version v1.2.0 2>&1)" && up_rc=0 || up_rc=$?
check "running it again upgrades to a newer release" test "$up_rc" = 0
check "…to its commit" test "$(git -C "$INST/katap" rev-parse HEAD)" = "$(tag_commit v1.2.0)"
check "…naming both releases" grep -qF "upgrading Katap from v1.1.0 to v1.2.0." <<<"$up_out"
again_out="$(installs --version v1.2.0 2>&1)" && again_rc=0 || again_rc=$?
check "running it again on the installed release provisions again" test "$again_rc" = 0 -a -e "$WORK/provisioned"
check "…and says it is already installed, not upgrading" \
    bash -c "grep -qF 'Katap v1.2.0 is already installed' <<<\"\$1\" && ! grep -q upgrading <<<\"\$1\"" _ "$again_out"
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
head_before="$(git -C "$INST/katap" rev-parse HEAD)"; rec_before="$(cat "$INST/release")"
latest_is v2.0.0
refuses "re-running the installer never moves to a new major version on its own" "of another major version, which changes how deploys work" installs
check "…and that refusal changed nothing" unchanged "$head_before" "$rec_before"
latest_is v1.4.0
check "an unnamed run within the same major version upgrades to the latest release" installs
check "…to its commit" test "$(git -C "$INST/katap" rev-parse HEAD)" = "$(tag_commit v1.4.0)"
# v1.0.0 was cloned by hand: a checkout with no release record.
latest_is v2.0.0
mv "$INST/release" "$WORK/release.kept"
refuses "a checkout with no release record is read from its tag, so it never crosses a major version unnamed" \
    "of another major version" installs
git -C "$INST/katap" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'not a release'
untagged="$(git -C "$INST/katap" rev-parse HEAD)"
refuses "…and one at no release tag is never moved without --version" "no release record" installs
check "…which left it where it was" test "$(git -C "$INST/katap" rev-parse HEAD)" = "$untagged"
git -C "$INST/katap" checkout -q --detach "$(tag_commit v1.4.0)"
mv "$WORK/release.kept" "$INST/release"
latest_is v1.1.0
check "a new major version installs when it is named" installs --version v2.0.0
refuses "an unnamed run never moves back across a major version either" "of another major version" installs
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

# --- deploy refusals that need no image ------------------------------------------

section "katap deploy / rollback / cron / backup with a fake docker"

refuses "a staging key cannot deploy a production component" "this key deploys staging only" \
    ideploy -- shop api "$D64" env=staging

# The tool must be the release it was cloned at. The fixture's host directory sits
# inside it here, so it is kept out of the repository, as /srv is on a host.
git -C "$K" init -q
echo /srv/ > "$K/.git/info/exclude"
git -C "$K" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$K" -c user.email=t@t -c user.name=t commit -qm fixture
ideploy -- shop api "$D64" env=production >/dev/null 2>&1 || true
check "a clean tool checkout goes on to the pull" grep -q '^pull' "$WORK/image.log"
echo '# local edit' >> "$K/templates/spa.yml"
refuses "a tool checkout with local modifications is refused" "has local modifications" ideploy -- shop api "$D64"
check "…before anything is pulled" bash -c "! grep -q '^pull' '$WORK/image.log'"
# An enclosing repository, as /srv could be: git must never fall back to it when
# the tool's own .git cannot be read.
git -C "$WORK" init -q
echo garbage > "$K/.git/HEAD.tmp"; mv "$K/.git/HEAD" "$K/.git/HEAD.bak"; mv "$K/.git/HEAD.tmp" "$K/.git/HEAD"
refuses "a checkout git cannot read is refused, never checked against an enclosing repository" "could not check" ideploy -- shop api "$D64"
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
envfile=''
prev=''
for arg in "\$@"; do
    [ "\$prev" = --project-name ] && project="\$arg"
    [ "\$prev" = --env-file ] && envfile="\$arg"
    prev="\$arg"
done
case " \$* " in
    *" image inspect "*) [ "\${FAKE_PRESENT:-}" = 1 ] && exit 0; exit 1 ;;
    *" image ls "*) printf '%s\n' \${FAKE_IMAGES:-}; exit 0 ;;
    *" pull "*) [ "\${FAKE_PULL_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
    *" config --services"*)
        if [ -n "\${FAKE_SLOW_SERVICES:-}" ]; then
            # One line at a time, the wanted service first: what real compose does.
            for svc in \$FAKE_SLOW_SERVICES; do echo "\$svc"; sleep 0.05; done
            exit 0
        fi
        exec docker "\$@" ;;
    *" config "*) exec docker "\$@" ;;
    *" ps -a "*) [ -n "\${FAKE_DOCKER_DOWN:-}" ] && exit 1; printf '%s\n' \${FAKE_PS:-}; exit 0 ;;
    *" volume ls "*) [ -n "\${FAKE_DOCKER_DOWN:-}" ] && exit 1; printf '%s\n' \${FAKE_VOLUMES:-}; exit 0 ;;
    *" up -d --wait"*)
        [ -n "\${FAKE_UP_FAIL:-}" ] && exit 1
        # Only the release that names this digest fails to become healthy.
        [ -n "\${FAKE_UP_FAIL_DIGEST:-}" ] && grep -qF "\$FAKE_UP_FAIL_DIGEST" "\$envfile" && exit 1
        exit 0 ;;
    *" run --rm -T --name "*)
        [ -n "\${FAKE_RUN_EXIT:-}" ] && exit "\$FAKE_RUN_EXIT"
        # A client that ignores TERM, so only the KILL after the grace stops it.
        [ -n "\${FAKE_RUN_IGNORE_TERM:-}" ] && trap '' TERM
        exec sleep "\${FAKE_RUN_SLEEP:-0}" ;;
    *"RENAME TO app"*) [ -n "\${FAKE_RENAME_FAIL:-}" ] && exit 1; exit 0 ;;
    *"DROP DATABASE app WITH"*) [ -n "\${FAKE_DROP_FAIL:-}" ] && exit 1; exit 0 ;;
    *" exec -T caddy cat "*) [ -z "\${FAKE_CADDYFILE:-}" ] || cat "\$FAKE_CADDYFILE"; exit 0 ;;
    *" ps -q "*) [ -n "\${FAKE_DB_DOWN:-}" ] || echo fake-container-id ;;
    *" pg_dump "*) [ "\$project" = "\${FAKE_DUMP_FAIL:-}" ] && exit 1; echo PGDMP-fake; exec sleep "\${FAKE_DUMP_SLEEP:-0}" ;;
esac
exit 0
STUB
chmod +x "$WORK/fake-docker"
fake() { : > "$WORK/fake.log"; KATAP_AUTHORIZED_KEYS="$WORK/rm-ak" KATAP_DOCKER="$WORK/fake-docker" katap "$@"; }

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
check "a rollback to an image still on this host needs no registry at all" \
    env FAKE_PRESENT=1 FAKE_PULL_FAIL=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api
check "…and pulled nothing" bash -c "! grep -q ' pull ' '$WORK/fake.log'"
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
refuses "a rollback names only a release this host has deployed" "never deployed here" \
    fake rollback shop api "$(rel 99)"
printf '{"projects": ' > "$K/srv/katap.json"
refuses "a rollback never depends on katap.json (a half-edited one leaves the way back open)" "never deployed here" \
    fake rollback shop api "$(rel 99)"
refuses "…while a deploy is held until it is fixed" "fix it and run 'katap apply'" fake deploy shop api "$D64"
rm -f "$K/srv/katap.json"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"
refuses "the first release has nothing before it" "no earlier release" fake rollback shop api

# A rollback goes back only: never forward past the release serving, whose
# migrations a later release's would build on.
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) "
    echo "2026-01-03T00:00:00Z deploy api IMAGE_API=$(rel 12) "
    echo "2026-01-04T00:00:00Z restore api IMAGE_API=$(rel 11) from api-x-scheduled.dump"
} > "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
: > "$WORK/fake.log"
refuses "after a restore, a rollback to a release deployed later is refused (its migrations are not in the data)" \
    "deploy it instead of rolling back" env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 12)"
check "…and nothing was started" bash -c "! grep -q ' up ' '$WORK/fake.log'"
check "a rollback to a release deployed before the one serving is allowed" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 10)"
check "…and records it" bash -c "tail -n 1 '$K/srv/state/shop/history' | grep -qE ' rollback api IMAGE_API=$(rel 10) '"
refuses "a staging key cannot roll back a production component" "this key deploys staging only" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api env=staging

# The release serving deployed again before a restore of a dump from its first
# time: what ran in between is cut off by the dump's own time.
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) "
    echo "2026-01-03T00:00:00Z rollback api IMAGE_API=$(rel 10) "
    echo "2026-01-04T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-05T00:00:00Z restore api IMAGE_API=$(rel 10) from api-20260101T120000Z-scheduled.dump"
} > "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"
refuses "a restore cuts off what was deployed after its dump, even when the release it put back was deployed again" \
    "deploy it instead of rolling back" env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 11)"
refuses "…and a bare rollback finds nothing before it" "no earlier release" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) "
    echo "2026-01-03T00:00:00Z restore api IMAGE_API=$(rel 10) from api-20260102T000000Z-predeploy.dump"
} > "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"
refuses "a deploy in the same second as the dump came after it, so the restore cuts it off" "deploy it instead of rolling back" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 11)"
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) "
    echo "2026-01-11T00:00:00Z restore api IMAGE_API=$(rel 30) from api-20260110T000000Z-scheduled.dump"
} > "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 30)" > "$K/srv/state/shop/images.env"
refuses "a dump from another server (a release never run here) cuts off everything before it" "no earlier release" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api
refuses "…a named release too" "deploy it instead of rolling back" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 11)"

# A release with a migrate image rolls back whole, never half.
m() { printf 'ghcr.io/acme/shop-api-migrate@sha256:%064d' "$1"; }
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) IMAGE_API_MIGRATE=$(m 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) IMAGE_API_MIGRATE=$(m 11) "
} > "$K/srv/state/shop/history"
printf 'IMAGE_API=%s\nIMAGE_API_MIGRATE=%s\n' "$(rel 11)" "$(m 11)" > "$K/srv/state/shop/images.env"
refuses "a rollback naming the runtime image without its migrate image is refused" "with that migrate image" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 10)"
check "a bare rollback puts back the runtime and migrate images of one release" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api
check "…both of them" bash -c "grep -qxF 'IMAGE_API=$(rel 10)' '$K/srv/state/shop/images.env' && grep -qxF 'IMAGE_API_MIGRATE=$(m 10)' '$K/srv/state/shop/images.env'"
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 10) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 11) "
    echo "2026-01-03T00:00:00Z deploy api IMAGE_API=$(rel 12) "
    echo "2026-01-04T00:00:00Z restore api IMAGE_API=$(rel 11) from api-x-scheduled.dump"
} > "$K/srv/state/shop/history"

# A component whose repository moved still rolls back to what it served before.
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
cp "$K/srv/projects/shop/api.conf" "$WORK/api.conf.before"
sed -i 's|^image=.*|image=ghcr.io/acme/moved-api|' "$K/srv/projects/shop/api.conf"
check "a rollback to a release of the component's previous repository works" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 10)"
refuses "…while a deploy from it is refused" "is not this component's repository" fake deploy shop api "$D64"
cp "$WORK/api.conf.before" "$K/srv/projects/shop/api.conf"

# A bare rollback picks its target once it holds the lock: a deploy that finishes
# meanwhile is the one it rolls back from.
echo "IMAGE_API=$(rel 12)" > "$K/srv/state/shop/images.env"
echo "2026-01-05T00:00:00Z deploy api IMAGE_API=$(rel 12) " >> "$K/srv/state/shop/history"
exec 5>"$K/srv/state/shop/.lock"
flock 5
# fd 5 closed in the child: it must wait on this shell's lock, not hold it.
( exec 5>&-; env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api >"$WORK/rolling.log" 2>&1 ) &
rolling=$!
# Until the rollback says it is waiting on the project's lock.
for _ in $(seq 1 100); do grep -qF 'waiting for another operation' "$WORK/rolling.log" 2>/dev/null && break; sleep 0.1; done
check "the bare rollback waits on the project's lock, and says so" grep -qF "waiting for another operation on 'shop'" "$WORK/rolling.log"
echo "2026-01-06T00:00:00Z deploy api IMAGE_API=$(rel 13) " >> "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 13)" > "$K/srv/state/shop/images.env"
exec 5>&-
wait "$rolling" || true
check "a rollback waiting on a deploy goes back from the release that deploy put live" \
    grep -qxF "IMAGE_API=$(rel 12)" "$K/srv/state/shop/images.env"

# The automatic rollback: a release that never becomes healthy is replaced by the
# one before it, and the state still names that one.
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
: > "$WORK/fake.log"
refuses "a release that never becomes healthy is rolled back to the one before it" "failed and was rolled back" \
    env FAKE_UP_FAIL_DIGEST="$(digest 1)" KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…by starting the release before it again" test "$(grep -c ' up -d --wait' "$WORK/fake.log")" -ge 2
check "…which the state still names" grep -qxF "IMAGE_API=$(rel 11)" "$K/srv/state/shop/images.env"
check "…and the failed release is recorded" bash -c "tail -n 1 '$K/srv/state/shop/history' | grep -qE ' failed api IMAGE_API=$D64'"
failed_before="$(grep -c ' failed api ' "$K/srv/state/shop/history")"
refuses "when the release before it does not come back either, the deploy says the component may be down" \
    "and so did putting the release before it back" \
    env FAKE_UP_FAIL=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…and still records the failed release" test "$(grep -c ' failed api ' "$K/srv/state/shop/history")" = "$((failed_before + 1))"

# A migration that never finishes is cut off, so the project's lock is freed.
: > "$WORK/fake.log"
started=$SECONDS
refuses "a pre-deploy service that runs past KATAP_PREDEPLOY_TIMEOUT is stopped and the deploy refused" "did not finish within 1s" \
    env KATAP_PREDEPLOY_TIMEOUT=1s FAKE_RUN_SLEEP=20 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…within the limit, not after the migration" test "$((SECONDS - started))" -lt 15
check "…its container removed by name" grep -qE '^rm -f shop-api-migrate-predeploy-[0-9]+$' "$WORK/fake.log"
check "…the release serving left as it was" grep -qxF "IMAGE_API=$(rel 11)" "$K/srv/state/shop/images.env"
check "…run with no terminal, so an admin's own terminal can never stall it" grep -qE ' run --rm -T --name shop-api-migrate-predeploy-[0-9]+ api-migrate' "$WORK/fake.log"
: > "$WORK/fake.log"
refuses "a migration killed at once (out of memory: 137) is a failure, not a timeout" "api-migrate failed (exit 137)" \
    env FAKE_RUN_EXIT=137 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
: > "$WORK/fake.log"
refuses "a KATAP_PREDEPLOY_TIMEOUT that is not a duration is refused" "must be a duration" \
    env KATAP_PREDEPLOY_TIMEOUT=soon KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…before anything is pulled or dumped" bash -c "! grep -qE '(^| )pull |pg_dump' '$WORK/fake.log'"
for bad in 0 09m 2d; do
    refuses "a KATAP_PREDEPLOY_TIMEOUT of '$bad' is refused (no limit, octal, or not timeout's)" "must be a duration" \
        env KATAP_PREDEPLOY_TIMEOUT="$bad" KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
done
: > "$WORK/fake.log"
refuses "a deploy with a backup remote and a KATAP_RCLONE_TIMEOUT that is not a duration is refused" "must be a duration" \
    env KATAP_RCLONE_REMOTE=remote:bucket KATAP_RCLONE_TIMEOUT=1d KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…before anything is pulled or dumped" bash -c "! grep -qE '(^| )pull |pg_dump' '$WORK/fake.log'"
check "…while a rollback, which uses neither, still works" \
    env KATAP_PREDEPLOY_TIMEOUT=soon FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 11)"
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
: > "$WORK/fake.log"
refuses "a pre-deploy client that ignores TERM is killed, and the deploy still reports the deadline" "did not finish within 1s" \
    env KATAP_PREDEPLOY_TIMEOUT=1s KATAP_KILL_AFTER=1s FAKE_RUN_IGNORE_TERM=1 FAKE_RUN_SLEEP=20 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…and its container is removed" grep -qE '^rm -f shop-api-migrate-predeploy-[0-9]+$' "$WORK/fake.log"

# An images.env every read of fails is never taken for an empty one: that would
# drop the other components' releases from it.
# A grep that fails every read of that one file, as an I/O error would.
mkdir -p "$WORK/eio-bin"
# shellcheck disable=SC2016 # the stub's own $@ and $last, written literally
printf '#!/usr/bin/env bash\nfor a in "$@"; do last="$a"; done\n[ "$last" != %q ] || { echo "grep: $last: Input/output error" >&2; exit 2; }\nexec %s "$@"\n' \
    "$K/srv/state/shop/images.env" "$(command -v grep)" > "$WORK/eio-bin/grep"
chmod +x "$WORK/eio-bin/grep"
eio_fake() { PATH="$WORK/eio-bin:$PATH" fake "$@"; }
images_before="$(cat "$K/srv/state/shop/images.env")"
refuses "a deploy refuses an images.env it cannot read" "could not read" eio_fake deploy shop api "$D64"
check "…and leaves it as it was" test "$images_before" = "$(cat "$K/srv/state/shop/images.env")"
refuses "…and so does the nightly backup, instead of skipping the component" "could not read" eio_fake backup shop

# A component deleted from katap.json stops deploying; its way back stays open.
projects_json '{"host": "203.0.113.10", "projects": {"other": {"web": {"type": "spa", "repo": "acme/other-web"}}}}'
refuses "a component deleted from katap.json no longer deploys, whoever holds its key" "no longer deploys" fake deploy shop api "$D64"
check "…while it still rolls back" env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop api "$(rel 10)"
projects_json '{"host": "203.0.113.10", "projects": {}}'
# This server's components were made by hand; the marker is what apply leaves.
: > "$K/srv/state/.applied"
refuses "once apply has run, removing the last project from katap.json stops its deploys too" "no longer deploys" fake deploy shop api "$D64"
rm -f "$K/srv/state/.applied"
fake deploy shop api "$D64" >/dev/null 2>&1 || true
check "on a server where apply never ran, a file that lists no project leaves components made by hand deploying" \
    bash -c "tail -n 1 '$K/srv/state/shop/history' | grep -qE ' deploy api IMAGE_API=$D64'"
rm -f "$K/srv/katap.json"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"

# A component with no release yet has nothing to run: its image is a placeholder.
refuses "katap run refuses a service of a component with no release" "has no release yet" fake run shop web
check "…and pulls and starts nothing" bash -c "! grep -qE ' (run|pull) ' '$WORK/fake.log'"

history_before="$(cat "$K/srv/state/shop/history")"
: > "$K/srv/state/shop/images.env"
refuses "a first deploy that never becomes healthy has nothing to roll back to" "no earlier release to roll back to" \
    env FAKE_UP_FAIL=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…and is still recorded, so remove never takes it for a component that never ran" \
    bash -c "tail -n 1 '$K/srv/state/shop/history' | grep -qE '^[0-9TZ:-]+ failed api IMAGE_API=$D64'"
printf '%s\n' "$history_before" > "$K/srv/state/shop/history"
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop/images.env"
fake deploy shop api "$D64" >/dev/null 2>&1 || true
check "a deploy completes with the fake docker" grep -q 'deploy api IMAGE_API=ghcr.io/acme/shop-api@' "$K/srv/state/shop/history"
check "…and does not reload the shared edge" bash -c "! grep -qE 'caddy (reload|validate)|katap-edge' '$WORK/fake.log'"
echo "IMAGE_API=$(rel 10)" > "$K/srv/state/shop/images.env"

check "katap run finds a service whatever line compose prints it on" \
    env FAKE_SLOW_SERVICES="api-scheduler api-redis api-db api-artisan api-migrate api-permissions api-worker api" \
        KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" run shop api-scheduler
: > "$WORK/fake.log"
refuses "a released component whose database is down is not deployed without a dump" "the pre-deploy dump failed" \
    env FAKE_DB_DOWN=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" deploy shop api "$D64"
check "…and no migration ran" bash -c "! grep -qE ' run .*api-migrate' '$WORK/fake.log'"
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

# A restore whose release is no longer here, and cannot be pulled, stops nothing.
dump="$(find "$K/srv/backups/shop2" -name 'api-*-scheduled.dump' | head -n 1)"
: > "$WORK/fake.log"
refuses "a restore that cannot get its release back is refused before anything stops" "could not pull" \
    env FAKE_PULL_FAIL=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" restore shop2 api "$dump" --confirm shop2
check "…so nothing was stopped and no data was touched" bash -c "! grep -qE ' stop | pg_restore | DROP ' '$WORK/fake.log'"

# A keep count of 0 would delete every dump, the one just taken included.
dumps_before="$(find "$K/srv/backups/shop2" -name '*.dump' | sort)"
refuses "a KATAP_BACKUP_KEEP below 1 is refused before a dump is taken" "KATAP_BACKUP_KEEP" \
    env KATAP_BACKUP_KEEP=0 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" backup shop2
check "…and every dump is still there" test "$dumps_before" = "$(find "$K/srv/backups/shop2" -name '*.dump' | sort)"
: > "$WORK/fake.log"
refuses "…and so is a restore with it, before anything stops" "KATAP_BACKUP_KEEP" \
    env KATAP_BACKUP_KEEP=0 FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" restore shop2 api "$dump" --confirm shop2
check "…which stopped nothing" bash -c "! grep -q ' stop ' '$WORK/fake.log'"
: > "$WORK/fake.log"
refuses "a restore with a KATAP_RCLONE_TIMEOUT that is not a duration is refused before anything stops" "must be a duration" \
    env KATAP_RCLONE_REMOTE=remote:bucket KATAP_RCLONE_TIMEOUT=1d FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" restore shop2 api "$dump" --confirm shop2
check "…and stopped nothing either" bash -c "! grep -q ' stop ' '$WORK/fake.log'"
mkdir -p "$WORK/rclone-fail-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/rclone-fail-bin/rclone"
chmod +x "$WORK/rclone-fail-bin/rclone"
restore_out="$(env PATH="$WORK/rclone-fail-bin:$PATH" KATAP_RCLONE_REMOTE=remote:bucket FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" \
    "$K/bin/katap" restore shop2 api "$dump" --confirm shop2 2>&1)" && restore_rc=0 || restore_rc=$?
check "a restore whose safety dump could not be copied off the host still restores (the dump is on the host)" \
    bash -c "[ $restore_rc = 0 ] && grep -qF 'the off-host copy failed' <<<\"\$1\" && ! grep -qF 'the database is unchanged' <<<\"\$1\"" _ "$restore_out"
refuses "a restore refuses a dump of another component (its data would replace this one's)" "is not a dump of 'web'" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" restore shop2 web "$dump" --confirm shop2
restore_state() { cat "$K/srv/state/shop2/images.env" "$K/srv/state/shop2/history"; }
state_before="$(restore_state)"
refuses "a restore that cannot drop the old database leaves everything as it was" "the database is unchanged" \
    env FAKE_DROP_FAIL=1 FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" restore shop2 api "$dump" --confirm shop2
check "…its release state and history included" test "$state_before" = "$(restore_state)"
echo "IMAGE_API=$(rel 11)" > "$K/srv/state/shop2/images.env"
swap_out="$(env FAKE_RENAME_FAIL=1 FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" \
    "$K/bin/katap" restore shop2 api "$dump" --confirm shop2 2>&1)" && swap_rc=0 || swap_rc=$?
check "a restore whose rename fails after the drop says so, and what to run" \
    bash -c "[ $swap_rc != 0 ] && grep -qF 'renaming it to app failed' <<<\"\$1\" && grep -qF 'katap rollback shop2 api ' <<<\"\$1\"" _ "$swap_out"
check "…having already recorded the dump's release and the restore, so the way back is cut as a restore requires" \
    bash -c "[ \"\$(sed -n 's/^IMAGE_API=//p' '$K/srv/state/shop2/images.env')\" = \"\$(sed -n 's/^IMAGE_API=//p' '$dump.images')\" ] && tail -n 1 '$K/srv/state/shop2/history' | grep -qE ' restore api IMAGE_API=.* from $(basename "$dump")\$'"
[ -e "$K/srv/secrets/shop2" ] || cp -R "$K/srv/secrets/shop" "$K/srv/secrets/shop2"
read -ra printed_args <<<"$(sed -n 's/.*katap rollback shop2 api //p' <<<"$swap_out")"
check "…and the command it prints is accepted" \
    env FAKE_PRESENT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" rollback shop2 api "${printed_args[@]}"

# An interrupted nightly dump leaves no partial file behind.
rm -f "$K/srv/backups/shop2/"*.partial
( exec setsid env FAKE_DUMP_SLEEP=30 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" "$K/bin/katap" backup shop2 >/dev/null 2>&1 ) &
dumping=$!
for _ in $(seq 1 100); do compgen -G "$K/srv/backups/shop2/*.partial" >/dev/null && break; sleep 0.1; done
check "a nightly dump in progress writes a partial file" compgen -G "$K/srv/backups/shop2/*.partial"
kill -TERM -- "-$dumping" 2>/dev/null || true
wait "$dumping" 2>/dev/null || true
check "…which is removed when the run is stopped (as systemd stops it at its time limit)" \
    bash -c "! compgen -G '$K/srv/backups/shop2/*.partial' >/dev/null"

# A backup remote that hangs is cut off: the nightly run fails instead of holding
# the project's lock until the unit's own limit.
mkdir -p "$WORK/rclone-bin"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$WORK/rclone-bin/rclone"
chmod +x "$WORK/rclone-bin/rclone"
started=$SECONDS
refuses "an off-host copy past KATAP_RCLONE_TIMEOUT fails the nightly run" "the off-host copy failed" \
    env PATH="$WORK/rclone-bin:$PATH" KATAP_RCLONE_REMOTE=remote:bucket KATAP_RCLONE_TIMEOUT=1s \
        KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" backup shop2
check "…within its limit" test "$((SECONDS - started))" -lt 20

# Image retention: only images of Katap's own components, only those no release needs.
{
    echo "2026-02-01T00:00:00Z deploy api IMAGE_API=$(rel 20) "
    echo "2026-02-02T00:00:00Z deploy api IMAGE_API=$(rel 21) "
    echo "2026-02-03T00:00:00Z deploy api IMAGE_API=$(rel 22) "
} > "$K/srv/state/shop2/history"
echo "IMAGE_API=$(rel 22)" > "$K/srv/state/shop2/images.env"
echo "IMAGE_API=$(rel 19)" > "$dump.images"
: > "$WORK/fake.log"
FAKE_IMAGES="$(rel 18) $(rel 19) $(rel 20) $(rel 21) $(rel 22) docker.io/library/postgres@sha256:$(printf '%064d' 5)" \
    KATAP_RELEASES_KEPT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" images prune >/dev/null 2>&1
check "images prune removes a release no rollback or restore needs" \
    bash -c "grep -qF 'image rm $(rel 18)' '$WORK/fake.log' && grep -qF 'image rm $(rel 20)' '$WORK/fake.log'"
check "…keeps what serves, the newest release and KATAP_RELEASES_KEPT before it, and every release a kept dump records" \
    bash -c "! grep -qE 'image rm ($(rel 19)|$(rel 21)|$(rel 22))' '$WORK/fake.log'"
check "…and never touches another image on the host" bash -c "! grep -q 'image rm docker.io/library/postgres' '$WORK/fake.log'"
# A release deployed again counts once: redeploying the serving one never pushes
# the release before it out of the rollback window.
{
    echo "2026-02-01T00:00:00Z deploy api IMAGE_API=$(rel 20) IMAGE_API_MIGRATE=$(rel 40) "
    echo "2026-02-02T00:00:00Z deploy api IMAGE_API=$(rel 21) IMAGE_API_MIGRATE=$(rel 41) "
    for _ in 1 2 3; do echo "2026-02-03T00:00:00Z deploy api IMAGE_API=$(rel 22) IMAGE_API_MIGRATE=$(rel 42) "; done
} > "$K/srv/state/shop2/history"
printf 'IMAGE_API=%s\nIMAGE_API_MIGRATE=%s\n' "$(rel 22)" "$(rel 42)" > "$K/srv/state/shop2/images.env"
: > "$WORK/fake.log"
FAKE_IMAGES="$(rel 20) $(rel 21) $(rel 22) $(rel 40) $(rel 41) $(rel 42)" \
    KATAP_RELEASES_KEPT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" images prune >/dev/null 2>&1
check "images prune counts a release deployed again once, so the one before it stays" \
    bash -c "! grep -qE 'image rm ($(rel 21)|$(rel 22))' '$WORK/fake.log' && grep -qF 'image rm $(rel 20)' '$WORK/fake.log'"
check "…and keeps a kept release's migrate image with it" \
    bash -c "! grep -qE 'image rm ($(rel 41)|$(rel 42))' '$WORK/fake.log' && grep -qF 'image rm $(rel 40)' '$WORK/fake.log'"
echo "IMAGE_API=$(rel 22)" > "$K/srv/state/shop2/images.env"
# The window follows the line a rollback walks: after a restore, the releases it
# cut off go, and the ones before the restored release stay.
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(rel 20) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(rel 21) "
    echo "2026-01-03T00:00:00Z deploy api IMAGE_API=$(rel 22) "
    echo "2026-01-04T00:00:00Z deploy api IMAGE_API=$(rel 23) "
    echo "2026-01-05T00:00:00Z restore api IMAGE_API=$(rel 21) from api-20260102T120000Z-scheduled.dump"
} > "$K/srv/state/shop2/history"
echo "IMAGE_API=$(rel 21)" > "$K/srv/state/shop2/images.env"
: > "$WORK/fake.log"
FAKE_IMAGES="$(rel 20) $(rel 21) $(rel 22) $(rel 23)" \
    KATAP_RELEASES_KEPT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" images prune >/dev/null 2>&1
check "after a restore, images prune keeps the release a rollback goes back to, not the ones the restore cut off" \
    bash -c "! grep -qE 'image rm ($(rel 20)|$(rel 21))' '$WORK/fake.log' && grep -qF 'image rm $(rel 23)' '$WORK/fake.log'"
echo "IMAGE_API=$(rel 22)" > "$K/srv/state/shop2/images.env"
# A repository the component moved away from is still Katap's to prune.
moved() { printf 'ghcr.io/acme/old-api@sha256:%064d' "$1"; }
{
    echo "2026-01-01T00:00:00Z deploy api IMAGE_API=$(moved 1) "
    echo "2026-01-02T00:00:00Z deploy api IMAGE_API=$(moved 2) "
    echo "2026-02-03T00:00:00Z deploy api IMAGE_API=$(rel 22) "
} > "$K/srv/state/shop2/history"
: > "$WORK/fake.log"
FAKE_IMAGES="$(moved 1) $(moved 2) $(rel 22)" \
    KATAP_RELEASES_KEPT=1 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" images prune >/dev/null 2>&1
check "images prune removes old releases of a repository the component moved away from, keeping the rollback window" \
    bash -c "grep -qF 'image rm $(moved 1)' '$WORK/fake.log' && ! grep -qE 'image rm ($(moved 2)|$(rel 22))' '$WORK/fake.log'"
exec 5>"$K/srv/state/shop2/.lock"
flock 5
: > "$WORK/fake.log"
started=$SECONDS
busy_out="$(FAKE_IMAGES="$(rel 18) $(rel 20)" KATAP_RELEASES_KEPT=2 KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" images prune 2>&1 || true)"
check "images prune never waits for a busy project" test "$((SECONDS - started))" -lt 5
check "…keeps every image of its repositories this time, and says so" \
    bash -c "grep -qF 'shop2 is busy' <<<\"\$1\" && ! grep -q 'image rm' '$WORK/fake.log'" _ "$busy_out"
exec 5>&-
rm -rf "$K/srv/projects/shop2" "$K/srv/state/shop2"

# Removing what was never deployed.
cp -R "$K/srv/projects/shop" "$K/srv/projects/typo"
sed -i 's/ shop-/ typo-/' "$K/srv/projects/typo/site.caddy"
printf '\n# web (spa)\nkeep.test {\n}\n' >> "$K/srv/projects/typo/site.caddy"
refuses "remove needs the project name repeated" "--confirm must repeat the project name" fake remove typo --confirm shop
mkdir -p "$K/srv/state/typo"
echo "IMAGE_API=$(rel 30)" > "$K/srv/state/typo/images.env"
refuses "remove refuses a component with a release serving" "it was deployed" fake remove typo api --confirm typo
: > "$K/srv/state/typo/images.env"
echo "2026-03-01T00:00:00Z deploy api IMAGE_API=$(rel 30) " > "$K/srv/state/typo/history"
refuses "…or one that was ever deployed" "has been deployed, or a deploy was attempted" fake remove typo api --confirm typo
rm -f "$K/srv/state/typo/history"
typo_sum() { find "$K/srv/projects/typo" "$K/srv/secrets/typo" -type f -exec sha256sum {} + 2>/dev/null | sort; }
mkdir -p "$K/srv/secrets/typo"
echo 'POSTGRES_PASSWORD=x' > "$K/srv/secrets/typo/api.db.env"
typo_before="$(typo_sum)"
refuses "remove refuses a component with containers" "has containers" env FAKE_PS='api-worker' KATAP_AUTHORIZED_KEYS="$WORK/rm-ak" KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" remove typo api --confirm typo
refuses "…or data volumes" "has data volumes" env FAKE_VOLUMES='api-db' KATAP_AUTHORIZED_KEYS="$WORK/rm-ak" KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" remove typo api --confirm typo
refuses "…and when Docker does not answer, it assumes nothing" "could not list typo's containers" env FAKE_DOCKER_DOWN=1 KATAP_AUTHORIZED_KEYS="$WORK/rm-ak" KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" remove typo api --confirm typo
check "…and those refusals left every file in place" test "$typo_before" = "$(typo_sum)"
cp -R "$K/srv/projects/typo" "$WORK/typo-saved"
rm -f "$K/srv/projects/typo/api.conf" "$K/srv/projects/typo/api.yml"
refuses "removing a project's last component never takes the secrets of one deleted by hand" "secrets of a component that is not being removed" \
    fake remove typo web --confirm typo
refuses "…nor its volumes" "still has containers or volumes" env FAKE_VOLUMES='api-db' KATAP_AUTHORIZED_KEYS="$WORK/rm-ak" KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$K/bin/katap" remove typo web --confirm typo
check "…and left the project in place" test -f "$K/srv/secrets/typo/api.db.env" -a -f "$K/srv/projects/typo/web.conf"
rm -rf "$K/srv/projects/typo"; mv "$WORK/typo-saved" "$K/srv/projects/typo"
rm -f "$K/srv/secrets/typo/api.db.env"
printf '%s\n' 'restrict,command="/srv/katap/bin/katap ssh-dispatch production typo api" ssh-ed25519 AAAA katap typo/api production' \
    'restrict,command="/srv/katap/bin/katap ssh-dispatch production typo apiv2" ssh-ed25519 BBBB katap typo/apiv2 production' \
    'ssh-ed25519 CCCC admin@laptop' > "$WORK/rm-ak"
printf '%s\n' "2026-03-01T00:00:00Z failed api IMAGE_API=$(rel 30) " > "$K/srv/state/typo/history"
refuses "remove refuses a component whose only deploy failed (it may have created data)" "a deploy was attempted" \
    fake remove typo api --confirm typo
: > "$K/srv/state/typo/history"
projects_json "$(jq '.projects.typo = {"api": .projects.shop.api}' <<<"$SHOP_JSON")"
refuses "remove refuses a component katap.json still lists (apply would create it again)" "remove it there first" \
    fake remove typo api --confirm typo
projects_json '{"projects": {"typo": ["api"]}}'
refuses "…and a katap.json of another shape, rather than read it as not listing it" "not a projects file katap can read" \
    fake remove typo api --confirm typo
# The typo's fix lists the domain under the right name while the typo still has
# it: the removal must not be held by the very conflict it resolves.
projects_json "$SHOP_JSON"
chmod 640 "$K/srv/projects/typo/site.caddy"
site_inode="$(stat -c %i "$K/srv/projects/typo/site.caddy")"
check "a component that never ran is removed, with its site block (another component's volume blocks nothing)" \
    bash -c "FAKE_VOLUMES='apiv2-db' KATAP_AUTHORIZED_KEYS='$WORK/rm-ak' KATAP_DOCKER='$WORK/fake-docker' KATAP_SRV='$K/srv' '$K/bin/katap' remove typo api --confirm typo >/dev/null 2>&1 && [ ! -e '$K/srv/projects/typo/api.conf' ] && ! grep -q '^# api (' '$K/srv/projects/typo/site.caddy' && grep -q '^# web (spa)' '$K/srv/projects/typo/site.caddy'"
check "…site.caddy replaced by a rename, keeping its mode (a failed write never truncates it)" \
    bash -c "[ \"\$(stat -c %i '$K/srv/projects/typo/site.caddy')\" != '$site_inode' ] && [ \"\$(stat -c %a '$K/srv/projects/typo/site.caddy')\" = 640 ]"
check "…and its deploy key, and only its own" \
    bash -c "! grep -q 'typo api\"' '$WORK/rm-ak' && grep -q 'typo apiv2\"' '$WORK/rm-ak' && grep -q admin@laptop '$WORK/rm-ak'"
check "…and a project left empty is removed whole" \
    bash -c "for c in '$K'/srv/projects/typo/*.conf; do c=\$(basename \"\$c\" .conf); KATAP_AUTHORIZED_KEYS='$WORK/rm-ak' KATAP_DOCKER='$WORK/fake-docker' KATAP_SRV='$K/srv' '$K/bin/katap' remove typo \"\$c\" --confirm typo >/dev/null 2>&1 || exit 1; done; [ ! -e '$K/srv/projects/typo' ] && [ ! -e '$K/srv/state/typo' ]"

# --- katap edge cloudflare / acme ------------------------------------------------

K_FAKE="$K"
K="$(new_katap)"
projects_json "$SHOP_JSON"
applies >/dev/null 2>&1
nest="$K/srv/secrets/blog/api.env"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=origin \
    -keyout "$WORK/origin.key" -out "$WORK/origin.pem" >/dev/null 2>&1
openssl genpkey -algorithm ec -pkeyopt ec_paramgen_curve:P-256 -out "$WORK/other.key" >/dev/null 2>&1
mkdir -p "$K/srv/edge"
printf 'TLS_MODE=internal\nCADDY_IP=10.254.0.2\nTLS_MODE=internal\n' > "$K/srv/edge/edge.env"
chmod 640 "$K/srv/edge/edge.env"
edge_sum() { sha256sum "$K/srv/edge/edge.env" "$nest"; ls -A "$K/srv/edge/certs" 2>/dev/null || true; }
kedge() { env KATAP_DOCKER="$WORK/fake-docker" KATAP_SRV="$K/srv" "$@"; }
edge_before="$(edge_sum)"
refuses "edge cloudflare refuses a key that is not the certificate's" "does not belong to the certificate; nothing was changed" \
    kedge "$K/bin/katap" edge cloudflare "$WORK/origin.pem" "$WORK/other.key"
check "…and changed nothing" test "$edge_before" = "$(edge_sum)"
refuses "an edge that does not start in Cloudflare mode is put back" "back in internal mode" \
    kedge FAKE_UP_FAIL=1 "$K/bin/katap" edge cloudflare "$WORK/origin.pem" "$WORK/origin.key"
check "…with its mode, and no application told to trust Cloudflare" \
    bash -c "[ \"\$(grep '^TLS_MODE=' '$K/srv/edge/edge.env')\" = TLS_MODE=internal ] && grep -qxF TRUST_CLOUDFLARE_HEADERS=false '$nest' && [ ! -e '$K/srv/edge/certs/origin.key' ]"
cf_out="$(kedge "$K/bin/katap" edge cloudflare "$WORK/origin.pem" "$WORK/origin.key" 2>&1)" && cf_rc=0 || cf_rc=$?
check "edge cloudflare installs the pair and Cloudflare's origin-pull CA" \
    bash -c "[ $cf_rc = 0 ] && cmp -s '$WORK/origin.pem' '$K/srv/edge/certs/origin.pem' && cmp -s '$REPO/edge/cloudflare-origin-pull-ca.pem' '$K/srv/edge/certs/cf-origin-pull-ca.pem' && [ \"\$(stat -c %a '$K/srv/edge/certs/origin.key')\" = 600 ] && [ \"\$(stat -c %a '$K/srv/edge/certs/origin.pem')\" = 644 ]"
check "…sets the mode once, keeping the settings file's mode" \
    bash -c "[ \"\$(grep -c '^TLS_MODE=' '$K/srv/edge/edge.env')\" = 1 ] && grep -qxF TLS_MODE=cloudflare '$K/srv/edge/edge.env' && grep -qxF CADDY_IP=10.254.0.2 '$K/srv/edge/edge.env' && [ \"\$(stat -c %a '$K/srv/edge/edge.env')\" = 640 ]"
check "…and only then tells each nestjs-api to trust Cloudflare's headers, naming it" \
    bash -c "grep -qxF TRUST_CLOUDFLARE_HEADERS=true '$nest' && grep -qxF '  blog/api' <<<\"\$1\"" _ "$cf_out"
cp "$K/srv/edge/certs/origin.pem" "$WORK/first.pem"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=rotated \
    -keyout "$WORK/rotated.key" -out "$WORK/rotated.pem" >/dev/null 2>&1
: > "$WORK/fake.log"
kedge FAKE_UP_FAIL=1 "$K/bin/katap" edge cloudflare "$WORK/rotated.pem" "$WORK/rotated.key" >/dev/null 2>&1 || true
check "a rotation the edge does not start with puts the previous certificate back" cmp -s "$WORK/first.pem" "$K/srv/edge/certs/origin.pem"
check "…and recreates the edge with it, since nothing else in its configuration changed" \
    test "$(grep -c 'up -d --wait --force-recreate caddy' "$WORK/fake.log")" = 2
: > "$WORK/fake.log"
kedge "$K/bin/katap" edge cloudflare "$WORK/rotated.pem" "$WORK/rotated.key" >/dev/null 2>&1
check "a rotation in Cloudflare mode recreates the edge, so it serves the new certificate" \
    bash -c "cmp -s '$WORK/rotated.pem' '$K/srv/edge/certs/origin.pem' && grep -qF 'up -d --wait --force-recreate caddy' '$WORK/fake.log'"

# An upgrade replaces the Caddyfile; the running edge keeps the one it started with.
: > "$WORK/fake.log"
kedge FAKE_CADDYFILE="$K/edge/Caddyfile" "$K/bin/katap" edge up >/dev/null 2>&1
check "edge up leaves a running edge alone when its Caddyfile is current" bash -c "! grep -q force-recreate '$WORK/fake.log'"
printf '# an older release\n' > "$WORK/old-Caddyfile"
kedge FAKE_CADDYFILE="$WORK/old-Caddyfile" "$K/bin/katap" edge up >/dev/null 2>&1
check "…and recreates it when the Caddyfile it serves is not the release's" grep -qF 'up -d --wait --force-recreate caddy' "$WORK/fake.log"
refuses "an edge that does not start in acme mode is put back in Cloudflare mode" "back in cloudflare mode" \
    kedge FAKE_UP_FAIL=1 "$K/bin/katap" edge acme
check "…with every application already distrusting Cloudflare's headers" \
    bash -c "grep -qxF TLS_MODE=cloudflare '$K/srv/edge/edge.env' && grep -qxF TRUST_CLOUDFLARE_HEADERS=false '$nest'"
cat > "$WORK/order-docker" <<STUB
#!/usr/bin/env bash
case " \$* " in *" up -d --wait"*) grep '^TRUST_CLOUDFLARE_HEADERS=' '$nest' > '$WORK/trust-at-up' ;; esac
exit 0
STUB
chmod +x "$WORK/order-docker"
env KATAP_DOCKER="$WORK/order-docker" KATAP_SRV="$K/srv" "$K/bin/katap" edge acme >/dev/null 2>&1 || true
check "edge acme stops each application trusting Cloudflare before the edge admits everyone" \
    bash -c "grep -qxF TRUST_CLOUDFLARE_HEADERS=false '$WORK/trust-at-up' && grep -qxF TLS_MODE=acme '$K/srv/edge/edge.env'"
K="$K_FAKE"

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
(SSH_ORIGINAL_COMMAND="deploy shop api $D64" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN=0 "$K/bin/katap" ssh-dispatch production shop api </dev/null | head -n 1 >/dev/null) || true
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
check "the deploy finishes after the session is closed" test -e "$WORK/detached-done"
for _ in $(seq 1 50); do [ -n "$(find "$K/srv/state/.dispatch/shop" -name '*.log.status')" ] && break; sleep 0.1; done
rm -f "$WORK/detached-done"
(SSH_ORIGINAL_COMMAND="deploy shop api $D64" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN=0 "$K/bin/katap" ssh-dispatch production shop api </dev/null >/dev/null 2>&1 &)
sleep 0.5
refuses "while a dispatched deploy runs, its worker holds the component's lock" "already running" dispatch "deploy shop api $D64"
refuses "…against every key bound to that component" "a dispatch for shop/api is already running" dispatch "deploy shop api $D64" production shop api,web
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
sleep 0.5
# A key bound to two components: one dispatch at a time across both, and the
# cooldown after it covers both.
rm -f "$WORK/detached-done"
(SSH_ORIGINAL_COMMAND="deploy shop api $D64" KATAP_SELF="$WORK/slow-self" KATAP_SRV="$K/srv" KATAP_SETTINGS="$K/katap.env" KATAP_DISPATCH_COOLDOWN=0 "$K/bin/katap" ssh-dispatch production shop api,web </dev/null >/dev/null 2>&1 &)
sleep 0.5
refuses "a key bound to two components cannot run the second while the first runs" "dispatch by this key" \
    dispatch "deploy shop web $D64" production shop api,web
for _ in $(seq 1 100); do [ -e "$WORK/detached-done" ] && break; sleep 0.1; done
sleep 0.5
refuses "…nor right after it, within the cooldown" "this key (shop/{api,web}) dispatched less than" \
    env KATAP_DISPATCH_COOLDOWN=60 bash -c "$(declare -f dispatch katap); K='$K' WORK='$WORK' STUBS='$STUBS'; dispatch 'deploy shop web $D64' production shop api,web"
check "the session receives the deploy's exit status" \
    bash -c "SSH_ORIGINAL_COMMAND='deploy shop api $D64' KATAP_SELF='$WORK/slow-self' SLOW_EXIT=3 KATAP_SRV='$K/srv' KATAP_SETTINGS='$K/katap.env' KATAP_DISPATCH_COOLDOWN=0 '$K/bin/katap' ssh-dispatch production shop api </dev/null >/dev/null 2>&1; [ \$? = 3 ]"
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
