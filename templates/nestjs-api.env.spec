# Secrets and settings for component __C__ (nestjs-api), generated ONCE by
# `kit secrets`. The application validates its environment at boot and refuses to
# start in production with anything missing; the full list, with what each value
# means, is nestjs-api's docs/deployment/README.md. Fill every `required` value on
# the host before the first deploy: `kit deploy` refuses while one is empty.

[db]
POSTGRES_PASSWORD=hex:32
APP_DB_PASSWORD=hex:32

[redis]
REDIS_PASSWORD=hex:32
REDISCLI_AUTH=same:REDIS_PASSWORD

[app]
NODE_ENV=literal:production
PORT=literal:3000
API_BASE_URL=literal:https://{domain}/api
WEB_BASE_URL=required
CORS_ORIGIN=required
DATABASE_URL=literal:postgresql://app:{secret:APP_DB_PASSWORD}@__C__-db:5432/app?schema=public
REDIS_HOST=literal:__C__-redis
REDIS_PORT=literal:6379
REDIS_PASSWORD=same:REDIS_PASSWORD
REDIS_URL=literal:redis://default:{secret:REDIS_PASSWORD}@__C__-redis:6379
JWT_SECRET=hex:48
# The one proxy hop whose X-Forwarded-For is believed: the edge's fixed address.
TRUST_PROXY=literal:{caddy_ip}
# Cloudflare's headers are trustworthy only when the edge admits nothing else.
TRUST_CLOUDFLARE_HEADERS=literal:{cloudflare}
EMAIL_PROVIDER=required
EMAIL_FROM=required
SMS_PROVIDER=required
STORAGE_PROVIDER=required
TURNSTILE_WEB_SECRET=required
TURNSTILE_MOBILE_SECRET=required
SEED_ADMIN_EMAIL=required
SEED_ADMIN_PASSWORD=hex:24
