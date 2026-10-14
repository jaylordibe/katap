# Secrets and settings for component __C__ (laravel-api), generated ONCE by
# `kit secrets`. Each line is KEY=GENERATOR; see the generator list in bin/kit.
# [app] is the API's environment (<component>.env); [db] is read only by the
# database container (<component>.db.env) and [redis] only by Redis
# (<component>.redis.env).
#
# Everything marked `required` must be filled in on the host before the first
# deploy: `kit deploy` refuses while one is empty. Anything else the application
# reads (mail credentials, storage, HORIZON_DASHBOARD_EMAILS, ...) is added to the
# generated file by hand; see the application's DEPLOYMENT.md §4.

[db]
POSTGRES_PASSWORD=hex:32
APP_DB_PASSWORD=hex:32

[redis]
REDIS_PASSWORD=hex:32
REDISCLI_AUTH=same:REDIS_PASSWORD

[app]
APP_NAME=literal:{project}
APP_ENV=literal:production
APP_DEBUG=literal:false
APP_KEY=laravel-key
APP_URL=literal:https://{domain}
APP_DOMAIN=literal:{domain}
APP_FRONTEND_URL=required
CORS_ALLOWED_ORIGINS=required
LOG_CHANNEL=literal:stderr
DB_CONNECTION=literal:pgsql
DB_HOST=literal:__C__-db
DB_PORT=literal:5432
DB_DATABASE=literal:app
DB_USERNAME=literal:app
DB_PASSWORD=same:APP_DB_PASSWORD
# Encrypted on the project network. `require` does not verify the self-signed
# server certificate; the link never leaves this host.
DB_SSLMODE=literal:require
REDIS_HOST=literal:__C__-redis
REDIS_PORT=literal:6379
REDIS_PASSWORD=same:REDIS_PASSWORD
CACHE_STORE=literal:redis
QUEUE_CONNECTION=literal:redis
SESSION_DRIVER=literal:redis
# One token both parsers accept: the base image's nginx and Laravel read this
# variable differently, and only a single CIDR satisfies both. Nothing outside this
# host can reach the container; public components of OTHER projects on the shared
# edge network can, and could set their own client address (README "Trusted
# proxies" and "Known limits").
TRUSTED_PROXIES=literal:0.0.0.0/0
PASSPORT_PRIVATE_KEY=rsa-private:passport
PASSPORT_PUBLIC_KEY=rsa-public:passport
MAIL_MAILER=required
MAIL_FROM_ADDRESS=required
