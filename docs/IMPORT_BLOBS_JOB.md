# ImportBlobsJob Implementation

## Overview

`ImportBlobsJob` is the most critical job in the Eurosky migration pipeline. It handles the transfer of all blobs (images, videos, and other media) from the old PDS to the new PDS. Blobs are streamed to/from disk via Net::HTTP, so memory usage per blob is limited to the HTTP chunk size (~16KB) regardless of blob size.

## File Location

```
app/jobs/import_blobs_job.rb
```

## Key Features

### 1. Concurrency Control
- **Maximum concurrent blob migrations**: Configurable via `MAX_CONCURRENT_BLOB_MIGRATIONS` (default 15)
- **Enforcement**: Checks count of migrations in `pending_download` or `pending_blobs` status
- **Behavior**: If at capacity, re-enqueues job with 30-second delay

### 2. Parallel Processing
- 50 worker threads pull blobs from a shared queue
- Each thread: Download → Upload → Cleanup
- Streaming I/O means memory is constant regardless of parallelism
- Throughput limited by network and PDS rate limits, not memory

### 3. Immediate File Cleanup
- Deletes local blob file after each upload
- Prevents disk space accumulation

### 4. Batched Progress Updates
- Database updates occur every **10 blobs** (not every blob)
- Reduces DB write load significantly
- Tracks:
  - `blobs_completed`: Number of blobs transferred
  - `blobs_total`: Total blob count
  - `bytes_transferred`: Total data transferred in bytes
  - `last_progress_update`: Timestamp of last update

### 5. Comprehensive Error Handling
- **Individual blob retries**: 3 attempts with exponential backoff
- **Partial failure tolerance**: Failed blobs logged but don't fail entire job
- **Failed blob tracking**: Stored in `progress_data['failed_blobs']`
- **Job-level retry**: 3 attempts with exponential backoff via ActiveJob

### 6. Post-Import Reconciliation
- After all blobs are transferred, checks account status for mismatches
- Uses `com.atproto.repo.listMissingBlobs` to find gaps
- Attempts to fetch and re-upload any missing blobs
- Best-effort: failures don't block migration

## Data Flow

```
1. Check concurrency limit
   ↓
2. Mark blobs_started_at timestamp
   ↓
3. List all blobs (cursor-based pagination, no auth required)
   ↓
4. Update migration record with blob_count
   ↓
5. Login to new PDS
   ↓
6. Process blobs in parallel (50 threads):
   ├─ Download to tmp/goat/{did}/blobs/{cid} (streamed to disk)
   ├─ Upload to new PDS (streamed from disk)
   ├─ Delete local file
   └─ Update progress (every 10th blob)
   ↓
7. Reconcile - verify all blobs imported, fill gaps
   ↓
8. Mark blobs_completed_at timestamp
   ↓
9. Advance to pending_prefs status
```

## Progress Tracking

The job stores detailed progress information in the `progress_data` JSONB field:

```json
{
  "blobs_started_at": "2026-01-27T10:00:00Z",
  "blobs_completed_at": "2026-01-27T10:45:30Z",
  "blob_count": 450,
  "blobs_completed": 450,
  "blobs_total": 450,
  "bytes_transferred": 1073741824,
  "last_progress_update": "2026-01-27T10:45:25Z",
  "failed_blobs": ["bafyreib...", "bafyreic..."]
}
```

## Configuration Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `REQUEUE_DELAY` | 30 seconds | Delay before re-enqueuing when at capacity |
| `MAX_BLOB_RETRIES` | 3 | Maximum retry attempts per blob |
| `PROGRESS_UPDATE_INTERVAL` | 10 | Update DB every N blobs |
| `PARALLEL_BLOB_TRANSFERS` | 50 | Number of concurrent worker threads |

## Error Scenarios

### 1. Individual Blob Failure
- **Behavior**: Logs error, adds to `failed_blobs`, continues with next blob
- **Retry**: 3 attempts with exponential backoff (2s, 4s, 8s)
- **Impact**: Does not fail entire job

### 2. Rate Limiting
- **Behavior**: Caught by retry mechanism with longer backoff (8s, 16s, 32s)
- **Job-level**: 5 retries with polynomial backoff
- **Impact**: Slows transfer, does not fail

### 3. Concurrency Limit Reached
- **Behavior**: Job re-enqueues itself with 30s delay
- **Retry**: Infinite until capacity available
- **Impact**: Job waits, does not fail

### 4. Job Failure
- **Behavior**: Marks migration as `failed` with error message
- **Retry**: 3 attempts via ActiveJob
- **Impact**: Migration enters failed state after all retries exhausted

## Integration Points

### GoatService Methods Used
- `login_new_pds` - Authenticate with destination PDS
- `list_blobs(cursor)` - List blobs with pagination
- `download_blob(cid)` - Stream blob to disk
- `upload_blob(blob_path)` - Stream blob from disk to PDS
- `get_account_status` - Check blob import completeness
- `collect_all_missing_blobs` - List missing blobs for reconciliation

### Migration Model Methods Used
- `advance_to_pending_prefs!` - Move to next pipeline stage
- `mark_failed!(error)` - Mark migration as failed
- `save!` - Persist progress updates

## Monitoring Queries

```ruby
# Check concurrent blob migrations
Migration.where(status: [:pending_download, :pending_blobs]).count

# Check concurrency diagnostics
DynamicConcurrencyService.diagnostics

# Check failed blobs for a migration
migration.progress_data['failed_blobs']

# Calculate success rate
completed = migration.progress_data['blobs_completed']
total = migration.progress_data['blobs_total']
success_rate = (completed.to_f / total * 100).round(2)
```

## Related Files

- `app/models/migration.rb` - Migration model with progress tracking
- `app/services/goat_service.rb` - ATProto client wrapper (streaming I/O)
- `app/services/dynamic_concurrency_service.rb` - Concurrency limit configuration
- `app/jobs/import_repo_job.rb` - Previous step (repository import)
- `app/jobs/import_prefs_job.rb` - Next step (preferences import)
