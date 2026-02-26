# CLAUDE.md — Eurosky Migration

## Project Overview

Eurosky Migration is a Rails 7.1 web application that migrates ATProto/Bluesky accounts between Personal Data Servers (PDS). It communicates directly with AT Protocol APIs (via minisky and HTTP) and provides a multi-step wizard UI with background job processing.

- **Framework**: Rails 7.1.5, Ruby 3.2.2
- **Database**: PostgreSQL 15
- **Background Jobs**: Sidekiq 7.2 + Redis 7
- **Deployment**: Docker Compose (4 services: postgres, redis, web, sidekiq)
- **Encryption**: Lockbox for credentials, Active Record Encryption
- **ATProto client**: minisky gem + direct HTTP

## Quick Commands

```bash
# Start the stack
docker compose up -d

# View logs
docker compose logs -f web
docker compose logs -f sidekiq

# Rails console
docker compose exec web rails console

# Run tests
docker compose exec web rails test              # Minitest
docker compose exec web bundle exec rspec        # RSpec

# Database
docker compose run --rm migrate bundle exec rails db:migrate

# Rebuild
docker compose build web && docker compose up -d web
```

## Project Structure

```
app/
├── controllers/
│   ├── application_controller.rb
│   ├── health_controller.rb
│   └── migrations_controller.rb      # Main controller (wizard + status + API)
├── helpers/
│   └── migration_error_helper.rb     # Error classification and user-facing messages
├── jobs/                             # 7 migration stage jobs + utilities
│   ├── create_account_job.rb
│   ├── download_all_data_job.rb
│   ├── upload_repo_job.rb / import_repo_job.rb
│   ├── upload_blobs_job.rb / import_blobs_job.rb
│   ├── import_prefs_job.rb
│   ├── wait_for_plc_token_job.rb
│   ├── update_plc_job.rb             # POINT OF NO RETURN
│   ├── activate_account_job.rb
│   └── cleanup_*.rb, retry_*.rb      # Utility jobs
├── mailers/
│   └── migration_mailer.rb           # All transactional emails
├── models/
│   └── migration.rb                  # State machine, encryption, progress tracking
├── services/
│   ├── goat_service.rb               # ATProto API client (minisky + HTTP)
│   ├── dynamic_concurrency_service.rb
│   └── legacy_blob_converter_service.rb
└── views/
    └── migrations/
        ├── new.html.erb              # Multi-step wizard form
        └── show.html.erb             # Status page with live updates
config/
├── locales/                          # 26 locale files (en, de, fr, es, etc.)
├── routes.rb                         # REST + token-based access routes
└── initializers/
    ├── eurosky_config.rb
    ├── lockbox.rb
    ├── sidekiq.rb
    └── redis.rb
```

## Non-Negotiables

### Localization (i18n) — MANDATORY

**All user-facing strings MUST be localized.** Never hardcode strings in views, controllers, mailers, helpers, or JavaScript.

- Use `t()` / `I18n.t()` for all text in Ruby code and ERB templates
- Add new keys to `config/locales/en.yml` first (English is the base locale)
- Follow the existing key hierarchy (e.g., `migrations.new.step1.title`, `controllers.migrations.verification_sent`)
- JavaScript strings go under `migrations.js.*` and are rendered via data attributes or inline script
- Mailer strings go under `mailers.*`
- Flash messages go under `controllers.migrations.*`
- Model validations go under `activerecord.errors.models.migration.*`
- Use interpolation (`%{variable}`) for dynamic values, never string concatenation
- The app supports 26 locales — when adding new keys to `en.yml`, the other locale files will need corresponding translations

### Security

- Credentials in env vars or Lockbox encryption, never in code
- Token-based access (EURO-xxxxxxxx), no authentication system
- Auto-expire sensitive data (48h credentials, 1h PLC tokens)

### Architecture

- Business logic in `app/services/`, not in models or controllers
- Thin models: validations, associations, scopes, state transitions only
- Jobs are sequential stages — each triggers the next on success
- `UpdatePlcJob` is the **point of no return** — treat with extreme care

## Migration Flow

```
CreateAccountJob → DownloadAllDataJob → UploadRepoJob → UploadBlobsJob
    → ImportPrefsJob → WaitForPlcTokenJob → UpdatePlcJob → ActivateAccountJob
```

## Key Environment Variables

See `.env.example` for the full list. Critical ones:
- `DATABASE_URL` — PostgreSQL connection
- `REDIS_URL` — Redis for Sidekiq
- `MASTER_KEY` — Lockbox encryption key
- `DOMAIN` — Public domain for URLs

## Testing

Both Minitest (`test/`) and RSpec (`spec/`) are present:
- `test/` — unit tests for models, services, controllers, integration tests
- `spec/` — RSpec tests for services, jobs, controllers, request specs

## Reference

- **u-at-proto test network**: `../` (parent directory)
- **ATProto docs**: Use the atproto MCP tools for protocol questions
