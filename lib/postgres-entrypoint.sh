#!/bin/sh
# Starts Katap's per-project PostgreSQL.
#
# 1. Refuses to start an empty cluster beside an existing one. The data volume is
#    /var/lib/postgresql and each major version keeps its cluster in <major>/docker,
#    so a changed image major would otherwise initialise a new, empty database and
#    the application would serve it. Upgrading a major is a deliberate
#    dump-and-restore (docs/operations.md, "Upgrading PostgreSQL").
# 2. With a certificate mounted at /katap/tls, serves TLS. PostgreSQL refuses a key
#    that its own user does not own or that others can read, and a bind mount
#    carries the host's owner and mode, so the pair is installed into the data
#    volume (as root, before the official entrypoint drops to the postgres user).
set -eu

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    for version_file in /var/lib/postgresql/*/docker/PG_VERSION; do
        [ -s "$version_file" ] || continue
        echo "katap: $PGDATA is empty but $(dirname "$version_file") holds a PostgreSQL $(cat "$version_file") cluster." >&2
        echo "katap: refusing to start an empty database beside it; see docs/operations.md, \"Upgrading PostgreSQL\"." >&2
        exit 1
    done
fi

if [ -s /katap/tls/server.key ]; then
    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/katap-tls
    install -o postgres -g postgres -m 0600 /katap/tls/server.key /var/lib/postgresql/katap-tls/server.key
    install -o postgres -g postgres -m 0644 /katap/tls/server.crt /var/lib/postgresql/katap-tls/server.crt
    exec docker-entrypoint.sh postgres \
        -c ssl=on \
        -c ssl_cert_file=/var/lib/postgresql/katap-tls/server.crt \
        -c ssl_key_file=/var/lib/postgresql/katap-tls/server.key \
        -c ssl_min_protocol_version=TLSv1.2
fi

exec docker-entrypoint.sh postgres
