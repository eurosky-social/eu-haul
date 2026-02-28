# ImportBlobsJob Implementation

## Overview

`ImportBlobsJob` is the most critical job in the Eurosky migration pipeline. It handles the transfer of all blobs (images, videos, and other media) from the old PDS to the new PDS. Blobs are streamed to/from disk via Net::HTTP, so memory usage per blob is limited to the HTTP chunk size (~16KB) regardless of blob size.

## File Location

```
app/jobs/import_blobs_job.rb
```

## Key Features

### 1. Unlimited Parallel Migrations
- **No global limit**: Every migration runs independently with no gating or queuing
- **Fixed per-migration threads**: 5 parallel blob transfers per migration (`PARALLEL_BLOBS`)
- **Resource isolation**: Blob jobs run on the `migrations` queue; critical jobs (emails, PLC updates) run on a separate `critical` queue so they're never blocked

### 2. Parallel Processing
- 5 worker threads pull blobs from a shared queue per migration
- Each thread: Download → Upload → Cleanup
- Streaming I/O means memory is constant regardless of parallelism
- Throughput limited by network and PDS rate limits, not memory

### 3. Immediate File Cleanup
- Deletes local blob file after each upload
- Prevents disk space accumulation

### 4. Batched Progress Updates
- Database updates occur every **10 blobs** (not every blob)
- Uses `with_connection` to borrow and return DB connections immediately
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
1. Mark blobs_started_at timestamp
   ↓
2. List all blobs (cursor-based pagination, no auth required)
   ↓
3. Update migration record with blob_count
   ↓
4. Login to new PDS
   ↓
5. Process blobs in parallel (5 threads):
   ├─ Download to tmp/goat/{did}/blobs/{cid} (streamed to disk)
   ├─ Upload to new PDS (streamed from disk)
   ├─ Delete local file
   └─ Update progress (every 10th blob)
   ↓
6. Reconcile - verify all blobs imported, fill gaps
   ↓
7. Mark blobs_completed_at timestamp
   ↓
8. Advance to pending_prefs status
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
| `PARALLEL_BLOBS` | 5 | Parallel blob transfer threads per migration |
| `MAX_BLOB_RETRIES` | 3 | Maximum retry attempts per blob |
| `PROGRESS_UPDATE_INTERVAL` | 10 | Update DB every N blobs |

## Error Scenarios

### 1. Individual Blob Failure
- **Behavior**: Logs error, adds to `failed_blobs`, continues with next blob
- **Retry**: 3 attempts with exponential backoff (2s, 4s, 8s)
- **Impact**: Does not fail entire job

### 2. Rate Limiting
- **Behavior**: Caught by retry mechanism with longer backoff (8s, 16s, 32s)
- **Job-level**: 5 retries with polynomial backoff
- **Impact**: Slows transfer, does not fail

### 3. Job Failure
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
# Check active blob transfer migrations
Migration.where(status: [:pending_download, :pending_blobs]).count

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
- `app/jobs/import_repo_job.rb` - Previous step (repository import)
- `app/jobs/import_prefs_job.rb` - Next step (preferences import)
