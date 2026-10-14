#!/bin/sh
#
# Post-deploy smoke check: passes only when GET <url> answers HTTP 200 and, when
# given, a body containing <body> (a fixed string).
#
#   lib/smoke-check.sh <url> [<body>]
#
# The single definition both checks use: `katap deploy` runs it inside a pinned curl
# container on the project network, and the Deploy workflow runs it on the runner
# against the public URL. POSIX sh, so it runs in both. tests/run.sh exercises it
# against a stub server.
#
# Outcomes:
#   200 (+ body)                                   pass
#   connection failure, timeout, 5xx               retry (the release may still be starting)
#   200 with any other body                        retry, then fail
#   3xx, 4xx, anything else                        fail at once
#
# Redirects are never followed: a probe that lands on a login page or another host
# has not proved this release is up. Every attempt is bounded by a connection
# timeout and a total timeout, so a hung server cannot stall the deploy.
#
# Tunable (the defaults are what deploys use):
#   SMOKE_ATTEMPTS (30), SMOKE_INTERVAL_SECONDS (2),
#   SMOKE_CONNECT_TIMEOUT_SECONDS (5), SMOKE_MAX_TIME_SECONDS (10),
#   SMOKE_INSECURE (unset; `1` skips certificate verification, for tests only)
set -u

url="${1:-}"
body="${2:-}"
attempts="${SMOKE_ATTEMPTS:-30}"
interval="${SMOKE_INTERVAL_SECONDS:-2}"
connect_timeout="${SMOKE_CONNECT_TIMEOUT_SECONDS:-5}"
max_time="${SMOKE_MAX_TIME_SECONDS:-10}"

if [ -z "$url" ]; then
  echo 'smoke check: no URL was given, so the release cannot be verified.' >&2
  exit 1
fi

insecure=''
if [ "${SMOKE_INSECURE:-}" = '1' ]; then
  insecure='--insecure'
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

has_expected_body() {
  [ -z "$body" ] || grep -qF -- "$body" "$body_file"
}

last=''
attempt=1
while [ "$attempt" -le "$attempts" ]; do
  : > "$body_file"
  # `|| code=000` stays a separate assignment: curl prints its -w output before
  # exiting, so `$(curl ... || echo 000)` would concatenate two codes.
  # shellcheck disable=SC2086 # $insecure is empty or one flag.
  code=$(curl --silent --show-error --proto '=http,https' $insecure \
    --connect-timeout "$connect_timeout" --max-time "$max_time" \
    --max-redirs 0 --output "$body_file" --write-out '%{http_code}' \
    "$url" 2>/dev/null) || code=000

  case "$code" in
    200)
      if has_expected_body; then
        echo "smoke check: ready after ${attempt} attempt(s): ${url}"
        exit 0
      fi
      status='HTTP 200 with an unexpected body'
      ;;
    000|5??)
      status="HTTP ${code}"
      ;;
    *)
      echo "smoke check failed: ${url} answered HTTP ${code}; expected 200." >&2
      exit 1
      ;;
  esac

  if [ "$status" != "$last" ]; then
    echo "smoke check: attempt ${attempt}: ${status}"
    last="$status"
  fi

  if [ "$attempt" -lt "$attempts" ]; then
    sleep "$interval"
  fi
  attempt=$((attempt + 1))
done

echo "smoke check failed after ${attempts} attempt(s): last result ${last} from ${url}." >&2
exit 1
