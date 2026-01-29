# Legacy Blob Format Conversion

## Overview

Pre-early 2023 Bluesky accounts contain records with a deprecated blob schema format that can cause migration failures on modern PDS implementations. This feature automatically detects and converts legacy blob references during migration.

## The Problem

### Legacy Format (pre-early 2023)
```json
{
  "cid": "bafkreigyia5vqnnpapjc6p5k23ukzc47kadxhbeuzfvjq52bftz7k2d56a",
  "mimeType": "image/jpeg"
}
```

### Current Format (February 2024+)
```json
{
  "$type": "blob",
  "ref": {
    "$link": "bafkreibabalobzn6cd366ukcsjycp4yymjymgfxcv6xczmlgpemzkz3cfa"
  },
  "mimeType": "image/png",
  "size": 760898
}
```

### Key Differences

| Property | Legacy | Current |
|----------|--------|---------|
| `$type` | Missing | Required ("blob") |
| CID location | `cid` (plain string) | `ref.$link` (wrapped) |
| `size` | Missing | Required (positive integer) |

## Why Migration Fails

The ATProto spec states implementations "should never write" legacy format, and since February 2024, PDS requires new format for record creation. During `importRepo`, legacy blob references may be rejected or cause silent failures.

## How It Works

When `CONVERT_LEGACY_BLOBS=true`, the migration process includes an additional step:

1. **Export Repository**: CAR file downloaded from source PDS
2. **Scan for Legacy Blobs**: Records are scanned for legacy blob format
3. **Fetch Blob Sizes**: Actual sizes retrieved via `com.atproto.sync.getBlob` HEAD requests
4. **Convert Format**: Legacy blobs transformed to current format
5. **Import Repository**: Converted CAR file imported to target PDS

## Configuration

### Enable Conversion

Add to your `.env` file:

```bash
# Legacy Blob Format Conversion
# Set to true to convert pre-2023 legacy blob format to current format during migration
CONVERT_LEGACY_BLOBS=true
```

### Default Behavior

By default, conversion is **disabled** (`CONVERT_LEGACY_BLOBS=false`) because:
- Not all accounts have legacy blobs (only pre-2023 accounts)
- Conversion adds processing time (requires HEAD request for each blob)
- Most modern accounts don't need this feature

## Performance Impact

Conversion adds time to the migration process:

- **Scanning**: ~1-2 seconds for typical repos
- **Blob Size Fetching**: ~100-200ms per blob (with rate limiting)
- **Conversion**: Negligible (in-memory operation)

**Example**: An account with 50 legacy blobs would add ~10-15 seconds to migration time.

## Implementation Details

### Service: `LegacyBlobConverterService`

Located at: `app/services/legacy_blob_converter_service.rb`

Key methods:
- `convert_if_needed(car_path)` - Main entry point
- `find_legacy_blobs(records)` - Recursive scan for legacy format
- `fetch_blob_sizes(legacy_blobs)` - Get sizes from source PDS
- `convert_records(records, blob_sizes)` - Transform to current format

### Integration Point: `ImportRepoJob`

The conversion happens between export and import:

```ruby
# Step 1: Export repository
car_path = goat.export_repo

# Step 1.5: Convert legacy blobs if enabled
if ENV['CONVERT_LEGACY_BLOBS'] == 'true'
  converted_car_path = goat.convert_legacy_blobs_if_needed(car_path)
  car_path = converted_car_path if converted_car_path != car_path
end

# Step 2: Import repository
goat.import_repo(car_path)
```

## Progress Tracking

The migration status page shows conversion progress:

- 🔄 **Converting**: Yellow banner while conversion is in progress
- ✅ **Converted**: Green banner when legacy blobs were successfully converted
- No banner: No legacy blobs found or conversion disabled

Progress data stored in `migration.progress_data`:

```json
{
  "legacy_blob_conversion_started_at": "2026-01-28T10:30:00Z",
  "legacy_blob_conversion_completed_at": "2026-01-28T10:30:15Z",
  "legacy_blobs_converted": true,
  "converted_car_path": "/tmp/goat/did:plc:abc/account.123.converted.car"
}
```

## Error Handling

If conversion fails:
1. Error is logged with full stack trace
2. Migration is marked as failed
3. User can retry with `CONVERT_LEGACY_BLOBS=false` if needed

Common errors:
- **Session expired**: Must be logged in to source PDS
- **Blob not found**: Blob CID doesn't exist on source PDS (uses -1 as sentinel)
- **Network timeout**: Rate limiting or network issues (retries automatically)

## Testing

### Test with Legacy Account

If you have a pre-2023 account with legacy blobs:

1. Enable conversion:
   ```bash
   echo "CONVERT_LEGACY_BLOBS=true" >> .env
   ```

2. Start migration as normal

3. Monitor logs for conversion activity:
   ```bash
   docker compose logs -f sidekiq | grep -i legacy
   ```

### Expected Log Output

```
[ImportRepoJob] Legacy blob conversion enabled - scanning CAR file
[LegacyBlobConverterService] Scanning CAR file for legacy blob references
[LegacyBlobConverterService] Extracted 42 records from CAR file
[LegacyBlobConverterService] Found 12 legacy blob references - starting conversion
[LegacyBlobConverterService] Fetching sizes for 12 blobs from source PDS
[LegacyBlobConverterService] Successfully fetched 12 blob sizes
[LegacyBlobConverterService] Converting legacy blobs in 42 records
[LegacyBlobConverterService] Converted legacy blobs in 8 records
[LegacyBlobConverterService] Legacy blob conversion completed
[ImportRepoJob] Legacy blobs converted: /tmp/goat/did:plc:abc/account.123.converted.car
```

## Known Limitations

1. **CAR File Rebuilding**: Current implementation doesn't fully rebuild CAR file structure. Instead, it relies on PDS to rebuild the MST (Merkle Search Tree) during import.

2. **Blob Size Sentinel**: If blob size cannot be fetched (404, timeout, etc.), uses `-1` as sentinel value. PDS may accept this or reject during validation.

3. **Re-signing**: Converted records may need re-signing depending on PDS implementation. This is handled automatically during import.

## Related Files

- `app/services/legacy_blob_converter_service.rb` - Core conversion logic
- `app/services/goat_service.rb` - Integration wrapper
- `app/jobs/import_repo_job.rb` - Job that triggers conversion
- `app/views/migrations/show.html.erb` - Progress display
- `.env` / `.env.example` - Configuration

## References

- [ATProto Blob Specification](https://atproto.com/specs/data-model#blob-type)
- [Bluesky PDS Implementation](https://github.com/bluesky-social/pds)
- [Indigo Reference Implementation](https://github.com/bluesky-social/indigo) - See `atproto/atdata/blob.go`

## Support

If you encounter issues with legacy blob conversion:

1. Check Sidekiq logs: `docker compose logs sidekiq | grep -i legacy`
2. Verify source PDS is accessible
3. Try disabling conversion: `CONVERT_LEGACY_BLOBS=false`
4. Report issues with migration token for debugging
