#!/usr/bin/env bash
# Run tests inside the eurosky-web Docker container

set -e
cd "$(dirname "$0")"

DB_URL="postgresql://postgres:\${POSTGRES_PASSWORD}@eurosky-postgres:5432/eurosky_migration_test"

echo "==> Ensuring test database exists..."
docker compose exec eurosky-web bash -c "RAILS_ENV=test DATABASE_URL=\"$DB_URL\" bundle exec rails db:create 2>/dev/null || true"

echo "==> Running test database migrations..."
docker compose exec eurosky-web bash -c "RAILS_ENV=test DATABASE_URL=\"$DB_URL\" bundle exec rails db:migrate"

echo "==> Running tests..."
docker compose exec eurosky-web bash -c "RAILS_ENV=test DATABASE_URL=\"$DB_URL\" bundle exec rails test $*"
