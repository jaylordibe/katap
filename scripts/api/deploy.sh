#!/usr/bin/env bash
set -euo pipefail

working_dir=$(pwd)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull the latest changes
cd "$script_dir/../../nginx/public/api"
git pull --rebase

# Deploy to docker container
commands="
composer install --no-dev --no-ansi --no-interaction --no-progress --optimize-autoloader
php artisan config:clear
php artisan route:clear
php artisan event:clear
php artisan view:clear
php artisan migrate --force
chown -R www-data:www-data bootstrap/cache
php artisan horizon:terminate
"
docker exec -t api-service bash -c "$commands"

# Navigate back to the working directory
cd "$working_dir"
