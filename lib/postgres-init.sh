#!/bin/sh
# Runs once, when the database volume is first initialised (docker-entrypoint-initdb.d).
#
# Creates the application's own role and its database (lib/app-database.sql). The
# application connects as this role, which owns its database and nothing else; the
# `postgres` superuser password stays in <component>.db.env, which only the
# database container reads.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
    -v app_password="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE app LOGIN PASSWORD :'app_password';
SQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -v db=app -f /katap/app-database.sql
