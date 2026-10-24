# shellcheck shell=bash
#
# End-to-end: a real deploy on the local Docker daemon. Sourced by tests/run.sh
# (E2E=1), which provides the harness (check, refuses, ok, not_ok, new_katap, katap, ...).
#
# Project `e2e`: laravel-api (built from a laravel-api checkout) + a static SPA,
# behind the edge in TLS_MODE=internal, published to a throwaway local registry so
# every deploy is by digest exactly as on a server.

section "end to end (local Docker)"

E2E_LARAVEL_API="${E2E_LARAVEL_API:-$(cd "$REPO/.." && pwd)/laravel-api}"
REGISTRY_IMAGE='registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8'
WHOAMI_IMAGE='traefik/whoami:v1.11@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab'
NGINX_IMAGE='nginx:alpine@sha256:df221db836e1754089190208cee7eeda94f233197056426eda74a43ab1abeac2'
CURL_IMAGE="$(grep -E "^CURL_IMAGE=" "$REPO/bin/katap" | cut -d"'" -f2)"
REG='localhost:5055'
# The edge's host ports, moved off 80/443 for a developer machine. Requests in this
# suite go to Caddy's fixed address on the edge network instead, from a curl
# container, so they do not depend on how this machine forwards published ports.
export EDGE_HTTP_PORT=18080 EDGE_HTTPS_PORT=18443
CADDY_IP="$(grep '^CADDY_IP=' "$REPO/edge/edge.env" | cut -d= -f2)"

e2e_teardown() {
    [ "${E2E_KEEP:-}" != 1 ] || { echo "  (E2E_KEEP=1: leaving the e2e resources running; KATAP=$K)"; return 0; }
    local project
    for project in e2e e2eecho; do
        docker compose -p "$project" down --volumes --remove-orphans >/dev/null 2>&1 || true
    done
    docker compose -p katap-edge down --volumes >/dev/null 2>&1 || true
    docker rm -f katap-e2e-registry >/dev/null 2>&1 || true
}

# Exit code 6 is curl's "could not resolve host": the name does not exist on that
# network, as opposed to a slow or refused connection.
unresolvable() {
    docker run --rm --network katap-edge --entrypoint sh "$CURL_IMAGE" \
        -c "curl -sS --max-time 5 telnet://$1 </dev/null; [ \$? -eq 6 ]"
}

reachable() {
    docker run --rm --network katap-edge --entrypoint sh "$CURL_IMAGE" \
        -c "curl -sS --max-time 5 -o /dev/null http://$1"
}

e2e() {
    [ -d "$E2E_LARAVEL_API" ] || { not_ok "end to end" "no laravel-api checkout at $E2E_LARAVEL_API"; return; }
    e2e_teardown

    # --- Images, published by digest ---------------------------------------------
    docker run -d --name katap-e2e-registry -p 5055:5000 "$REGISTRY_IMAGE" >/dev/null

    local build_args=()
    if [ -n "${E2E_BASE_IMAGE:-}" ]; then
        local pinned
        pinned="$(grep -m1 '^FROM ' "$E2E_LARAVEL_API/Dockerfile" | awk '{print $2}')"
        build_args=(--build-context "$pinned=docker-image://$E2E_BASE_IMAGE")
        echo "  (laravel-api is built on $E2E_BASE_IMAGE instead of its pinned $pinned)"
    fi
    if ! docker buildx build --load "${build_args[@]}" -t "$REG/katap-e2e/laravel-api:1" "$E2E_LARAVEL_API" >"$WORK/build.log" 2>&1; then
        not_ok "build the laravel-api image" "$(tail -n 30 "$WORK/build.log")"
        return
    fi
    ok "build the laravel-api image from $E2E_LARAVEL_API"

    publish() { docker push --quiet "$1" >/dev/null && docker image inspect --format '{{index .RepoDigests 0}}' "$1"; }
    local ref1 ref2 broken spa
    ref1="$(publish "$REG/katap-e2e/laravel-api:1")"
    # A second, healthy release (a different digest), and one that never becomes healthy.
    printf 'FROM %s\nLABEL katap.e2e=2\n' "$ref1" | docker build -q -t "$REG/katap-e2e/laravel-api:2" - >/dev/null
    ref2="$(publish "$REG/katap-e2e/laravel-api:2")"
    printf 'FROM %s\nHEALTHCHECK CMD ["false"]\n' "$ref1" | docker build -q -t "$REG/katap-e2e/laravel-api:broken" - >/dev/null
    broken="$(publish "$REG/katap-e2e/laravel-api:broken")"
    mkdir -p "$WORK/spa"
    echo '<!doctype html><title>e2e</title><p>e2e spa</p>' > "$WORK/spa/index.html"
    printf 'FROM %s\nCOPY index.html /usr/share/nginx/html/index.html\n' "$NGINX_IMAGE" > "$WORK/spa/Dockerfile"
    docker build -q -t "$REG/katap-e2e/spa:1" "$WORK/spa" >/dev/null
    spa="$(publish "$REG/katap-e2e/spa:1")"
    check "every release is a registry digest" bash -c "for r in '$ref1' '$ref2' '$broken' '$spa'; do [[ \$r =~ @sha256:[0-9a-f]{64}\$ ]] || exit 1; done"

    # --- The project, defined the way the README says: katap.json, then apply --
    K="$(new_katap)"
    # This host's edge settings, overriding the tool's defaults.
    mkdir -p "$K/srv/edge"
    echo TLS_MODE=internal > "$K/srv/edge/edge.env"
    # The images come from a local registry; a deploy pulls them by digest.
    jq -n --arg api "$REG/katap-e2e/laravel-api" --arg web "$REG/katap-e2e/spa" '{
        host: "127.0.0.1",
        projects: {e2e: {
            api: {type: "laravel-api", repo: "katap-e2e/laravel-api", image: $api, domains: ["api.e2e.test"]},
            web: {type: "spa", repo: "katap-e2e/spa", image: $web, domains: ["www.e2e.test"]}
        }}}' > "$K/srv/katap.json"
    check "katap apply defines the project from katap.json" katap apply --yes
    local env="$K/srv/secrets/e2e/api.env"
    check "…the API's frontend and CORS origins taken from the web component" \
        bash -c "grep -qxF APP_FRONTEND_URL=https://www.e2e.test '$env' && grep -qxF CORS_ALLOWED_ORIGINS=https://www.e2e.test '$env'"
    sed -i -e 's|^MAIL_MAILER=$|MAIL_MAILER=log|' -e 's|^MAIL_FROM_ADDRESS=$|MAIL_FROM_ADDRESS=noreply@e2e.test|' "$env"
    # Test-only: an admin to sign in as. A real deployment never seeds users.
    printf 'SYSAD_EMAIL=sysad@e2e.test\nSYSAD_PASSWORD=e2e-%s\nAPPAD_EMAIL=appad@e2e.test\nAPPAD_PASSWORD=e2e-%s\n' \
        "$(openssl rand -hex 8)" "$(openssl rand -hex 8)" >> "$env"
    local secrets_before
    secrets_before="$(sha256sum "$K"/srv/secrets/e2e/*.env)"

    check "katap edge up" katap edge up

    # --- First deploy: migrate → permissions → worker → api → smoke ------------
    local out order
    if out="$(katap deploy e2e api "$ref1" 2>&1)"; then
        ok "first deploy of the laravel-api"
    else
        not_ok "first deploy of the laravel-api" "$(tail -n 40 <<<"$out")"
        e2e_teardown
        return
    fi
    order="$(grep -oE 'running api-(migrate|permissions)|starting api(-worker)?\.' <<<"$out" | tr '\n' ' ')"
    check "deploy order is migrate, permissions, worker, api" \
        test "$order" = 'running api-migrate running api-permissions starting api-worker. starting api. '
    check "the release is recorded by digest" grep -qxF "IMAGE_API=$ref1" "$K/srv/state/e2e/images.env"
    check "deploy the SPA" katap deploy e2e web "$spa"

    # edge <host> <curl args...>: a request to Caddy as a browser would make it.
    edge() {
        docker run --rm --network katap-edge "$CURL_IMAGE" -sS --max-time 10 -k \
            --resolve "$1:443:$CADDY_IP" --resolve "$1:80:$CADDY_IP" "${@:2}"
    }
    ready() { edge api.e2e.test "https://api.e2e.test/api/health/ready" | grep -qF '"status":"ready"'; }

    check "readiness through the edge over HTTPS" ready
    check "the SPA through the edge" grep -qF 'e2e spa' <<<"$(edge www.e2e.test https://www.e2e.test/ || true)"
    check "HTTP is redirected to HTTPS" \
        test "$(edge api.e2e.test -o /dev/null -w '%{http_code}' http://api.e2e.test/up || true)" = 308
    check "HSTS is sent" grep -qi '^strict-transport-security: max-age=31536000' <<<"$(edge api.e2e.test -D - -o /dev/null https://api.e2e.test/up || true)"
    check "the edge's host ports answer (published by the edge alone)" \
        test -n "$(docker port katap-edge-caddy-1 443/tcp 2>/dev/null || true)"

    # --- The client address: Caddy overwrites a forged X-Forwarded-For ----------
    mkdir -p "$K/srv/projects/e2eecho"
    cat > "$WORK/echo.yml" <<EOF
services:
  echo:
    image: $WHOAMI_IMAGE
    networks:
      edge:
        aliases: [e2eecho-echo]
networks:
  edge:
    name: katap-edge
    external: true
EOF
    printf 'echo.e2e.test {\n\timport katap_site\n\timport katap_proxy e2eecho-echo:80\n}\n' > "$K/srv/projects/e2eecho/site.caddy"
    docker compose -p e2eecho -f "$WORK/echo.yml" up -d --wait >/dev/null 2>&1
    katap edge reload >/dev/null 2>&1
    local echoed client_ip
    echoed="$(edge echo.e2e.test -H 'X-Forwarded-For: 6.6.6.6' https://echo.e2e.test/ || true)"
    check "the echo service answers through the edge" grep -q '^GET / ' <<<"$echoed"
    check "a forged X-Forwarded-For does not reach the application" bash -c "[ -n '$echoed' ] && ! grep -q '6\.6\.6\.6' <<<'$echoed'"
    check "the application receives exactly one client address" \
        test "$(grep -ciE '^X-Forwarded-For: [0-9a-f.:]+.?$' <<<"$echoed")" = 1
    local cf_echoed
    cf_echoed="$(edge echo.e2e.test -H 'CF-Connecting-IP: 7.7.7.7' https://echo.e2e.test/ || true)"
    check "a client-sent CF-Connecting-IP never reaches the application outside Cloudflare mode" \
        bash -c "grep -q '^GET / ' <<<'$cf_echoed' && ! grep -qi '^Cf-Connecting-Ip:' <<<'$cf_echoed'"
    check "the application is told the request was HTTPS" grep -qiE '^X-Forwarded-Proto: https' <<<"$echoed"
    client_ip="$(grep -i '^X-Forwarded-For:' <<<"$echoed" | awk '{print $2}' | tr -d '\r' || true)"
    edge api.e2e.test -H 'X-Forwarded-For: 6.6.6.6' -o /dev/null https://api.e2e.test/up || true
    sleep 1
    local api_log
    api_log="$(docker compose -p e2e logs --no-log-prefix api 2>&1 | grep 'GET /up' || true)"
    check "Laravel's nginx never logs the forged client address" bash -c "! grep -q '6\.6\.6\.6' <<<'$api_log'"
    check "Laravel's nginx logs the real client address (${client_ip:-none})" bash -c "[ -n '$client_ip' ] && grep -q '^$client_ip ' <<<'$api_log'"

    # --- Isolation --------------------------------------------------------------
    check "only the edge publishes host ports" \
        test -z "$(docker ps --filter label=com.docker.compose.project=e2e --format '{{.Ports}}' | grep -- '->' || true)"
    check "positive control: a public component is reachable on the edge network" reachable e2e-api:80/up
    check "another project cannot even resolve this project's database" unresolvable api-db:5432
    check "another project cannot even resolve this project's Redis" unresolvable api-redis:6379

    # --- First-deploy bootstrap, a token, and a redeploy that keeps it ----------
    check "bootstrap: the Passport personal access client" \
        katap run e2e api-artisan passport:client --personal --name=E2E --provider=users --no-interaction
    check "test-only: seed an admin" katap run e2e api-artisan db:seed --class=UserSeeder --force --no-interaction
    local password token
    password="$(grep '^SYSAD_PASSWORD=' "$env" | cut -d= -f2)"
    token="$(edge api.e2e.test -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d "{\"identifier\":\"sysad@e2e.test\",\"password\":\"$password\"}" \
        https://api.e2e.test/api/auth/sign-in | jq -r '.token // empty' || true)"
    authed() { edge api.e2e.test -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Accept: application/json' https://api.e2e.test/api/users/auth || true; }
    check "sign-in through the edge issues a token" test -n "$token"
    check "the token authenticates" test "$(authed)" = 200

    check "deploy a second release" katap deploy e2e api "$ref2"
    check "the token still authenticates after a redeploy (APP_KEY and Passport keys unchanged)" test "$(authed)" = 200
    check "no deploy rewrote a secret" test "$secrets_before" = "$(sha256sum "$K"/srv/secrets/e2e/*.env)"

    # --- A healthy container whose smoke check fails is rolled back ------------
    # (the smoke check, not only the container healthcheck, decides a deploy)
    set_conf e2e api smoke_body never-in-the-readiness-body
    refuses "a release whose smoke check fails is rolled back" "failed and was rolled back" \
        env SMOKE_ATTEMPTS=2 SMOKE_INTERVAL_SECONDS=1 KATAP_SRV="$K/srv" "$K/bin/katap" deploy e2e api "$ref1"
    set_conf e2e api smoke_body '"status":"ready"'
    check "…and the release before it is still recorded" grep -qxF "IMAGE_API=$ref2" "$K/srv/state/e2e/images.env"
    check "…and serving" ready

    # --- A release that never becomes healthy is rolled back --------------------
    refuses "an unhealthy release fails the deploy" "failed and was rolled back" katap deploy e2e api "$broken"
    check "after the failed deploy the previous release is still recorded" grep -qxF "IMAGE_API=$ref2" "$K/srv/state/e2e/images.env"
    check "…and is serving" ready
    check "the failure is in the history" grep -qF " failed api IMAGE_API=$broken" "$K/srv/state/e2e/history"

    check "katap rollback returns to the release before the current one" katap rollback e2e api
    check "…which is the first release" grep -qxF "IMAGE_API=$ref1" "$K/srv/state/e2e/images.env"
    check "…and it serves an existing session" test "$(authed)" = 200

    # --- Scheduler, backups, restore -------------------------------------------
    check "katap cron runs the scheduler once" katap cron e2e
    check "katap backup dumps the database" katap backup e2e
    local dump
    dump="$(find "$K/srv/backups/e2e" -name 'api-*-scheduled.dump' | head -n1 || true)"
    check "every redeploy left a pre-deploy dump" test -n "$(find "$K/srv/backups/e2e" -name 'api-*-predeploy.dump')"
    check "the dump records the release it was taken from" grep -qxF "IMAGE_API=$ref1" "$dump.images"
    check "the dump is a readable PostgreSQL archive" \
        docker run --rm -v "$K/srv/backups/e2e:/b:ro" --entrypoint pg_restore \
            "$(grep -m1 -oE 'postgres:[^ ]+' "$REPO/templates/laravel-api.yml")" --list "/b/$(basename "$dump")"

    # After the dump: a table appears (as a later migration would) and a newer
    # release goes live. A restore must remove the first and bring back the release
    # of the dump.
    psql_app() { docker compose -p e2e exec -T api-db psql -X -q -v ON_ERROR_STOP=1 -U app -d app "$@"; }
    psql_app -c 'CREATE TABLE katap_e2e_after_dump (id int); INSERT INTO katap_e2e_after_dump VALUES (1);' >/dev/null
    check "a newer release is deployed after the dump" katap deploy e2e api "$ref2"

    refuses "restore demands the project name as confirmation" "--confirm must repeat" katap restore e2e api "$dump" --confirm other
    cp "$dump" "$WORK/orphan.dump"
    refuses "restore refuses a dump whose release is unknown" "the release that wrote this dump is unknown" \
        katap restore e2e api "$WORK/orphan.dump" --confirm e2e
    printf 'not a dump' > "$WORK/broken.dump"
    cp "$dump.images" "$WORK/broken.dump.images"
    refuses "a dump that cannot be restored fails loudly" "the restore failed; the database is unchanged" \
        katap restore e2e api "$WORK/broken.dump" --confirm e2e
    check "…and changes nothing" test "$(psql_app -tA -c 'SELECT count(*) FROM katap_e2e_after_dump')" = 1
    check "…and the API serves again" ready

    docker compose -p e2e exec -T api-redis sh -c 'redis-cli SET katap-e2e-after-dump 1' >/dev/null
    check "restore replaces the data and the release" \
        env KATAP_BACKUP_KEEP=1 KATAP_SRV="$K/srv" "$K/bin/katap" restore e2e api "$dump" --confirm e2e
    check "…leaving nothing created after the dump" \
        test -z "$(psql_app -tA -c "SELECT to_regclass('katap_e2e_after_dump')")"
    check "…serving the release the dump was taken from" grep -qxF "IMAGE_API=$ref1" "$K/srv/state/e2e/images.env"
    check "…the restored dump still on disk" test -s "$dump"
    check "…and a safety dump taken first" test -n "$(find "$K/srv/backups/e2e" -name 'api-*-prerestore.dump')"
    check "…queued jobs and caches from after the dump are cleared" \
        test -z "$(docker compose -p e2e exec -T api-redis sh -c 'redis-cli GET katap-e2e-after-dump' | tr -d '\r')"
    check "…and the restore is in the history" grep -q " restore api IMAGE_API=$ref1 from " "$K/srv/state/e2e/history"
    check "the restored database still holds the admin's session" test "$(authed)" = 200
    check "a deploy after the restore migrates cleanly" katap deploy e2e api "$ref2"

    e2e_teardown
}

e2e
