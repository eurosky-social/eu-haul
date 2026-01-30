# Sidekiq Scheduler Setup

## ✅ Installation Complete

Sidekiq-scheduler has been successfully installed and configured to automatically clean up expired backup bundles.

## Configuration

### Gems Added

```ruby
# Gemfile
gem "sidekiq-scheduler", "~> 5.0"
gem "rubyzip", "~> 2.3"  # For ZIP file creation
```

### Schedule Configuration

File: `config/sidekiq.yml`

```yaml
:scheduler:
  :schedule:
    cleanup_expired_backups:
      cron: '0 * * * *'  # Every hour at minute 0
      class: CleanupBackupBundleJob
      queue: low
      description: "Clean up expired backup bundles (24h TTL)"
```

## Verification

Check that the schedule is loaded:

```bash
docker compose logs eurosky-sidekiq | grep -i "Loading Schedule"
```

Expected output:
```
INFO: Loading Schedule
INFO: Scheduling cleanup_expired_backups {"cron"=>"0 * * * *", "class"=>"CleanupBackupBundleJob", "queue"=>"low", "description"=>"Clean up expired backup bundles (24h TTL)"}
INFO: Schedules Loaded
```

## How It Works

1. **Cron Schedule**: Runs every hour at minute 0 (e.g., 1:00, 2:00, 3:00, etc.)
2. **Job**: `CleanupBackupBundleJob` scans for migrations with expired backups
3. **Cleanup**: Deletes ZIP bundles and downloaded data directories
4. **TTL**: 24 hours from `backup_created_at`

## Manual Execution

To manually trigger cleanup (for testing):

```bash
# Via Rails console
docker compose exec eurosky-web rails console
> CleanupBackupBundleJob.perform_now
```

Or via Rails runner:

```bash
docker compose exec eurosky-web rails runner "CleanupBackupBundleJob.perform_now"
```

## Monitoring

### Check Schedule Status

```bash
# View all scheduled jobs
docker compose exec eurosky-web rails console
> require 'sidekiq-scheduler'
> Sidekiq.schedule
```

### View Next Run Time

```bash
docker compose logs eurosky-sidekiq | grep cleanup_expired_backups
```

## Troubleshooting

### Schedule Not Loading

If you see this warning:
```
WARN: :schedule option should be under the :scheduler: key
```

Make sure your `config/sidekiq.yml` has the schedule under `:scheduler:` key (already fixed).

### Job Not Running

Check Sidekiq logs:
```bash
docker compose logs -f eurosky-sidekiq
```

Verify the job class exists:
```bash
docker compose exec eurosky-web rails console
> CleanupBackupBundleJob
```

## Production Notes

- The cron schedule uses **UTC timezone** by default
- To change timezone, add to `config/initializers/sidekiq_scheduler.rb`:
  ```ruby
  SidekiqScheduler::Scheduler.instance.rufus_scheduler_options = {
    :tz => 'America/New_York'
  }
  ```
- Monitor disk space to ensure cleanup is working
- Consider alerts if cleanup job fails repeatedly

## Alternative: Cron Job

If you prefer using system cron instead of sidekiq-scheduler:

```bash
# Add to crontab
0 * * * * cd /path/to/eurosky-migration && docker compose exec -T eurosky-web rails runner "CleanupBackupBundleJob.perform_now"
```

## Testing

To test the cleanup job with a 1-minute expiry:

```bash
docker compose exec eurosky-web rails console

# Create a test migration with expired backup
m = Migration.last
m.update!(
  backup_bundle_path: '/some/path.zip',
  backup_expires_at: 1.minute.ago
)

# Run cleanup
CleanupBackupBundleJob.perform_now

# Check logs
# Should see: "Cleaned up migration EURO-XXXXXXXX: freed X MB"
```

## Status

✅ Installed: sidekiq-scheduler 5.0.6
✅ Installed: rubyzip 2.4.1
✅ Configured: hourly cleanup schedule
✅ Running: Sidekiq scheduler active
✅ Verified: Schedule loaded successfully

All automatic cleanup is now active!
