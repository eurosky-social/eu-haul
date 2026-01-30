# Backup Bundle and Rotation Keys Implementation

This document describes the new features added to the Eurosky Migration Tool for backup bundle creation and rotation key management.

## Overview

Three major features have been implemented:

1. **Optional Backup Bundle** - Download complete account data before migration
2. **Rotation Keys** - Account recovery keys for reverting PLC changes
3. **S3 Blob Storage** - Documentation (no implementation needed - handled by PDS)

---

## Feature 1: Backup Bundle System

### What It Does

Users can optionally create a downloadable backup of their complete account data before migration:
- Repository (CAR file with all posts, likes, follows, profile)
- All blobs (images, videos, media attachments)
- Metadata (migration info, timestamps)

### User Flow

```
User submits form with "Create backup bundle" checked (default: ON)
  ↓
DownloadAllDataJob downloads repo + blobs to local disk
  ↓
CreateBackupBundleJob creates ZIP bundle
  ↓
Email notification sent when ready
  ↓
User downloads bundle (24h availability)
  ↓
Migration proceeds automatically
```

**If backup disabled:**
```
User unchecks "Create backup bundle" checkbox
  ↓
Migration starts immediately (no download phase)
  ↓
Uses existing stream download-upload flow
```

### Implementation Details

#### New Migration Statuses

- `pending_download` - Downloading all data (repo + blobs)
- `pending_backup` - Creating backup ZIP bundle
- `backup_ready` - Backup available for download

#### New Jobs

1. **DownloadAllDataJob** ([app/jobs/download_all_data_job.rb](u-at-proto/eurosky-migration/app/jobs/download_all_data_job.rb))
   - Downloads repo CAR file + all blobs from old PDS
   - Stores in `tmp/migrations/{did}/`
   - Parallel downloads (10 concurrent)
   - Progress tracking

2. **CreateBackupBundleJob** ([app/jobs/create_backup_bundle_job.rb](u-at-proto/eurosky-migration/app/jobs/create_backup_bundle_job.rb))
   - Creates ZIP archive from downloaded data
   - Includes metadata JSON
   - Stores in `tmp/bundles/{token}/backup.zip`
   - Sends email notification

3. **UploadRepoJob** ([app/jobs/upload_repo_job.rb](u-at-proto/eurosky-migration/app/jobs/upload_repo_job.rb))
   - Uploads repo from local file (if backup enabled)
   - Used instead of ImportRepoJob when data is pre-downloaded

4. **UploadBlobsJob** ([app/jobs/upload_blobs_job.rb](u-at-proto/eurosky-migration/app/jobs/upload_blobs_job.rb))
   - Uploads blobs from local files (if backup enabled)
   - Parallel uploads (10 concurrent)
   - Used instead of ImportBlobsJob when data is pre-downloaded

5. **CleanupBackupBundleJob** ([app/jobs/cleanup_backup_bundle_job.rb](u-at-proto/eurosky-migration/app/jobs/cleanup_backup_bundle_job.rb))
   - Scheduled job (hourly recommended)
   - Deletes expired backups (24h TTL)
   - Frees disk space

#### Database Changes

New fields added to `migrations` table:
- `create_backup_bundle` (boolean, default: true) - User's choice
- `downloaded_data_path` (string) - Path to downloaded data
- `backup_bundle_path` (string) - Path to ZIP bundle
- `backup_created_at` (datetime) - Backup creation timestamp
- `backup_expires_at` (datetime) - Expiry timestamp (24h)
- `rotation_private_key_ciphertext` (text, encrypted) - Rotation key

#### Email Notification

**MigrationMailer** ([app/mailers/migration_mailer.rb](u-at-proto/eurosky-migration/app/mailers/migration_mailer.rb))
- `backup_ready` action sends HTML + text email
- Includes download link with 24h expiry notice
- Beautiful HTML template with gradient header

#### Controller Changes

**MigrationsController** ([app/controllers/migrations_controller.rb](u-at-proto/eurosky-migration/app/controllers/migrations_controller.rb))
- New action: `download_backup` - Serves ZIP file for download
- Updated `migration_params` to accept `create_backup_bundle`

#### Routes

```ruby
# ID-based
GET /migrations/:id/download_backup

# Token-based (preferred)
GET /migrate/:token/download
```

#### UI Changes

**Form** ([app/views/migrations/new.html.erb](u-at-proto/eurosky-migration/app/views/migrations/new.html.erb))
- Checkbox: "Create backup bundle before migration" (default: checked)
- Helper text explaining 24h availability

**Status Page** ([app/views/migrations/show.html.erb](u-at-proto/eurosky-migration/app/views/migrations/show.html.erb))
- Download progress indicator (pending_download, pending_backup)
- Download button when backup is ready
- Expiry countdown timer
- Size display

### Storage Structure

```
tmp/
├── migrations/{did}/          # Downloaded data (temporary)
│   ├── repo.car               # Repository export
│   └── blobs/
│       ├── {cid1}
│       ├── {cid2}
│       └── ...
└── bundles/{token}/           # Backup bundles
    └── backup.zip             # ZIP archive
        ├── repo.car
        ├── blobs/
        │   └── ...
        └── metadata.json
```

### Cleanup Schedule

**Recommended Cron Job:**

```bash
# Run hourly
0 * * * * cd /rails && bundle exec rails runner "CleanupBackupBundleJob.perform_now"
```

Or use **sidekiq-scheduler** (add to `config/sidekiq.yml`):

```yaml
:schedule:
  cleanup_backups:
    cron: '0 * * * *'  # Every hour
    class: CleanupBackupBundleJob
```

---

## Feature 2: Rotation Keys

### What It Does

Generates and provides users with a **rotation key** (private key) that:
- Allows reverting PLC directory changes
- Enables account recovery
- Added to new PDS account with highest priority

### How It Works

1. **During Account Creation** (CreateAccountJob):
   - Generates P-256 rotation key pair using `goat key generate`
   - Stores private key encrypted in migration record
   - Adds public key to new PDS account with `--first` flag (highest priority)

2. **User Access**:
   - Private key displayed on status page
   - Copy-to-clipboard button
   - Detailed reversion instructions

### Implementation Details

#### CreateAccountJob Changes

Added rotation key generation after account creation:

```ruby
# Step 3.5: Generate rotation key
rotation_key = goat.generate_rotation_key
migration.set_rotation_key(rotation_key[:private_key])

# Step 3.6: Add to new PDS account (highest priority)
goat.add_rotation_key_to_pds(rotation_key[:public_key])
```

#### GoatService Methods

**New methods** ([app/services/goat_service.rb](u-at-proto/eurosky-migration/app/services/goat_service.rb)):

1. `generate_rotation_key` - Generates P-256 key pair
   - Calls: `goat key generate --type P-256`
   - Returns: `{ private_key: "z...", public_key: "did:key:z..." }`

2. `add_rotation_key_to_pds` - Adds key to account
   - Calls: `goat account plc add-rotation-key --first`
   - Prepends key to rotation key array (highest priority)

#### UI Display

**Status Page Section:**
- Warning box with rotation key display
- Monospace font for easy copying
- Copy-to-clipboard button
- Expandable "How to Use" instructions

### Reversion Process (for users)

```bash
# 1. Install goat CLI
go install github.com/bluesky-social/indigo/cmd/goat@latest

# 2. Get PLC history
goat plc history <your-did>

# 3. Find desired historical state (CID)
# Look for the CID before the migration

# 4. Create reversion operation
goat plc update --prev <historical-cid>

# 5. Sign with rotation key
goat plc sign --rotation-key <your-rotation-key>

# 6. Submit signed operation
goat plc submit --did <your-did>
```

### Security Notes

- Rotation keys are **encrypted** using Lockbox (same as passwords)
- Private keys **never leave** the server except when displayed to user
- Users are instructed to save keys securely
- Maximum **5 rotation keys** allowed per account (PLC limit)

---

## Feature 3: S3 Blob Storage

### Research Findings

**No implementation needed** for the migration tool itself:

1. **PDS Handles Storage**:
   - Blobs are uploaded via `com.atproto.repo.uploadBlob` endpoint
   - The PDS decides where to store them (local disk, S3, etc.)
   - Migration tool is just a pass-through

2. **Current Setup**:
   - PDS uses local disk at `/app/data/blobs`
   - Configured via `PDS_BLOBSTORE_DISK_LOCATION` env var

3. **For Production S3**:
   - Configure the **PDS service** (not migration tool)
   - PDS supports S3 via environment variables
   - Migration tool continues using same upload API

### Migration Flow

```
DownloadAllDataJob:
  Downloads blob from old PDS → Saves to local disk

UploadBlobsJob:
  Reads blob from local disk → Uploads to new PDS via uploadBlob API

New PDS:
  Receives blob → Stores to configured backend (disk/S3)
```

The migration tool is **storage-agnostic** - it just uploads blobs to the PDS API.

---

## Testing the Implementation

### Manual Testing Steps

1. **Start Migration with Backup**:
   ```bash
   # Access form
   open http://localhost:3001

   # Fill form with "Create backup bundle" CHECKED
   # Submit
   ```

2. **Monitor Progress**:
   ```bash
   # Watch logs
   docker compose logs -f eurosky-sidekiq

   # Check status page
   open http://localhost:3001/migrate/EURO-XXXXXXXX
   ```

3. **Verify Backup**:
   - Wait for email notification
   - Check backup is downloadable
   - Verify ZIP contents
   - Check 24h expiry timer

4. **Test Without Backup**:
   - Submit new migration with checkbox UNCHECKED
   - Verify migration starts immediately
   - Confirm no download/backup phase

5. **Test Rotation Key**:
   - Check rotation key appears on status page
   - Test copy-to-clipboard button
   - Verify key is saved in database (encrypted)

6. **Test Cleanup**:
   ```bash
   # Wait 24 hours or manually set expiry
   docker compose exec eurosky-web rails console
   > m = Migration.last
   > m.update!(backup_expires_at: 1.minute.ago)
   > exit

   # Run cleanup job
   docker compose exec eurosky-web rails runner "CleanupBackupBundleJob.perform_now"

   # Verify files deleted
   ls tmp/bundles/
   ls tmp/migrations/
   ```

### Unit Tests (TODO)

Create tests for:
- DownloadAllDataJob
- CreateBackupBundleJob
- UploadRepoJob / UploadBlobsJob
- CleanupBackupBundleJob
- Migration model (backup methods)
- GoatService (rotation key methods)
- MigrationsController (download action)

---

## Configuration

### Environment Variables

No new environment variables required. Existing variables still apply:

```bash
# Email (for backup notifications)
MAILER_FROM_EMAIL=noreply@eurosky-migration.local
DOMAIN=localhost:3001

# Storage
# (All storage is in tmp/ directory by default)
```

### Scheduled Jobs

Add to crontab or sidekiq-scheduler:

```yaml
# config/sidekiq.yml
:schedule:
  cleanup_expired_backups:
    cron: '0 * * * *'  # Every hour
    class: CleanupBackupBundleJob
    queue: low
```

---

## Architecture Diagrams

### Flow Comparison

**With Backup Enabled (Approach B - Efficient):**

```
User Form → DownloadAllDataJob (downloads repo + blobs)
              ↓
            CreateBackupBundleJob (creates ZIP)
              ↓
            Email notification → User downloads (optional)
              ↓
            CreateAccountJob (+ rotation key generation)
              ↓
            UploadRepoJob (uploads from local file)
              ↓
            UploadBlobsJob (uploads from local files)
              ↓
            ImportPrefsJob → ... → Complete
```

**Without Backup (Legacy Flow):**

```
User Form → CreateAccountJob (+ rotation key generation)
              ↓
            ImportRepoJob (stream download-upload)
              ↓
            ImportBlobsJob (stream download-upload)
              ↓
            ImportPrefsJob → ... → Complete
```

### State Machine

```
Form Submit
  ↓
[create_backup_bundle?]
  YES ↓                  NO ↓
pending_download    pending_account
  ↓
pending_backup
  ↓
backup_ready
  ↓
pending_account ←-------- (both converge here)
  ↓
account_created
  ↓
pending_repo
  ↓
pending_blobs
  ↓
pending_prefs
  ↓
pending_plc
  ↓
pending_activation
  ↓
completed
```

---

## File Changes Summary

### New Files Created

- `app/jobs/download_all_data_job.rb`
- `app/jobs/create_backup_bundle_job.rb`
- `app/jobs/upload_repo_job.rb`
- `app/jobs/upload_blobs_job.rb`
- `app/jobs/cleanup_backup_bundle_job.rb`
- `app/mailers/migration_mailer.rb`
- `app/views/migration_mailer/backup_ready.html.erb`
- `app/views/migration_mailer/backup_ready.text.erb`
- `db/migrate/20260130113716_add_backup_bundle_fields_to_migrations.rb`

### Modified Files

- `app/models/migration.rb` - Added backup/rotation key methods, new states
- `app/controllers/migrations_controller.rb` - Added download_backup action
- `app/services/goat_service.rb` - Added rotation key methods
- `app/jobs/create_account_job.rb` - Added rotation key generation
- `app/views/migrations/new.html.erb` - Added backup checkbox
- `app/views/migrations/show.html.erb` - Added backup/rotation key sections
- `config/routes.rb` - Added download routes

---

## Production Deployment Checklist

- [ ] Run database migration: `rails db:migrate`
- [ ] Set up scheduled job for CleanupBackupBundleJob (hourly)
- [ ] Configure email settings (SMTP for backup notifications)
- [ ] Verify storage permissions for `tmp/migrations/` and `tmp/bundles/`
- [ ] Set up monitoring for backup bundle creation failures
- [ ] Document rotation key usage for users
- [ ] Test email delivery
- [ ] Set up alerts for failed backup creations
- [ ] Consider storage limits (backups can be large)
- [ ] Plan for storage scaling if needed

---

## Security Considerations

1. **Rotation Keys**:
   - Encrypted at rest using Lockbox
   - Never transmitted over network (except to user display)
   - Users responsible for secure storage

2. **Backup Bundles**:
   - Token-based access (no authentication)
   - 24-hour TTL (automatic deletion)
   - Stored in non-public tmp directory

3. **Email Notifications**:
   - Download links use token-based authentication
   - Links expire after 24 hours
   - No sensitive data in email body

---

## Performance Considerations

1. **Disk Space**:
   - Backups can be large (GBs for accounts with many media files)
   - Cleanup job runs hourly to free space
   - Monitor disk usage in production

2. **Download Efficiency**:
   - Approach B downloads once, uses for backup + upload
   - More efficient than downloading twice
   - Trades disk space for bandwidth

3. **Parallel Processing**:
   - 10 concurrent downloads
   - 10 concurrent uploads
   - Configurable via constants in job files

---

## Next Steps

1. **Testing**: Create comprehensive test suite
2. **Documentation**: Add user-facing docs for rotation key usage
3. **Monitoring**: Set up alerts for backup failures
4. **Optimization**: Consider compression options for backups
5. **Storage**: Plan for S3/external storage for backup bundles (optional)

---

## Questions & Answers

### Q: Do I need to implement S3 storage for blobs?

**A:** No. The PDS handles all blob storage after upload. If you want S3 in production, configure the PDS service, not the migration tool.

### Q: What if a user skips the backup?

**A:** The migration proceeds immediately using the existing stream download-upload flow (ImportRepoJob + ImportBlobsJob).

### Q: How do rotation keys help?

**A:** They allow users to revert PLC directory changes if something goes wrong. The key is added to the new PDS account with highest priority.

### Q: What happens after 24 hours?

**A:** The CleanupBackupBundleJob automatically deletes expired backup bundles and downloaded data to free disk space.

### Q: Can users download their backup after migration completes?

**A:** Yes, as long as it's within 24 hours of creation. After that, it's automatically deleted.

---

## Support

For issues or questions:
- Check logs: `docker compose logs -f eurosky-sidekiq`
- Rails console: `docker compose exec eurosky-web rails console`
- Job status: Check Sidekiq UI (if configured)
