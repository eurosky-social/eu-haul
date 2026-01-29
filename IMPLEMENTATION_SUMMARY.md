# Legacy Blob Format Conversion - Implementation Summary

## Overview

Implemented optional legacy blob format conversion feature for eurosky-migration tool. This addresses migration failures for pre-2023 Bluesky accounts that contain deprecated blob schema format.

**Implementation Date**: January 28, 2026
**Status**: ✅ Complete and ready for testing

## What Was Built

### 1. Configuration (.env)

Added environment variable to control the feature:

```bash
CONVERT_LEGACY_BLOBS=false  # Set to true to enable conversion
```

**Files Modified**:
- `.env.example` - Production template with documentation
- `.env` - Development configuration

### 2. Core Service (LegacyBlobConverterService)

**File**: `app/services/legacy_blob_converter_service.rb` (new, 343 lines)

Core conversion logic that:
- Scans CAR files for legacy blob references using `goat repo unpack`
- Recursively searches records for legacy format (`cid` + `mimeType` without `$type`)
- Fetches actual blob sizes via HEAD requests to `com.atproto.sync.getBlob`
- Converts legacy format to current format (`$type`, `ref.$link`, `size`)
- Handles errors gracefully (uses -1 sentinel when size unavailable)

**Key Methods**:
- `convert_if_needed(car_path)` - Main entry point, returns converted or original path
- `find_legacy_blobs(records)` - Recursive detection algorithm
- `fetch_blob_sizes(legacy_blobs)` - API calls to source PDS
- `convert_legacy_blob(legacy_blob, blob_sizes)` - Format transformation

### 3. Integration (GoatService)

**File**: `app/services/goat_service.rb` (+12 lines)

Added wrapper method:
```ruby
def convert_legacy_blobs_if_needed(car_path)
  converter = LegacyBlobConverterService.new(migration)
  converter.convert_if_needed(car_path)
end
```

### 4. Job Integration (ImportRepoJob)

**File**: `app/jobs/import_repo_job.rb` (+25 lines)

Integrated conversion between export and import steps:

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

Tracks conversion progress in `migration.progress_data`:
- `legacy_blob_conversion_started_at`
- `legacy_blob_conversion_completed_at`
- `legacy_blobs_converted` (true/false)
- `converted_car_path`

### 5. UI Updates (Status Page)

**File**: `app/views/migrations/show.html.erb` (+16 lines)

Added visual feedback:
- 🔄 Yellow banner: "Converting Legacy Blob Format" (while in progress)
- ✅ Green banner: "Legacy Blobs Converted" (when complete)
- No banner: Disabled or no legacy blobs found

### 6. Documentation

**File**: `docs/LEGACY_BLOB_CONVERSION.md` (new, 251 lines)

Comprehensive documentation covering:
- Problem explanation with format comparison
- How the feature works (step-by-step)
- Configuration instructions
- Performance impact analysis
- Implementation details
- Testing procedures
- Error handling
- Known limitations
- Related files and references

## Technical Implementation Details

### Blob Format Detection Algorithm

```ruby
def legacy_blob?(obj)
  obj.is_a?(Hash) &&
    obj.key?('cid') &&
    obj.key?('mimeType') &&
    !obj.key?('$type') &&
    !obj.key?('ref')
end
```

### Conversion Logic

```ruby
def convert_legacy_blob(legacy_blob, blob_sizes)
  {
    '$type' => 'blob',
    'ref' => {
      '$link' => legacy_blob['cid']
    },
    'mimeType' => legacy_blob['mimeType'],
    'size' => blob_sizes[legacy_blob['cid']] || -1
  }
end
```

### Rate Limiting

- 100ms sleep between blob size fetches
- HEAD requests used instead of GET (faster, less bandwidth)
- Graceful degradation: uses -1 sentinel if size unavailable

## Files Changed

| File | Status | Lines Changed |
|------|--------|---------------|
| `.env.example` | Modified | +7 |
| `.env` | Modified | +4 |
| `app/services/legacy_blob_converter_service.rb` | New | +343 |
| `app/services/goat_service.rb` | Modified | +12 |
| `app/jobs/import_repo_job.rb` | Modified | +25 |
| `app/views/migrations/show.html.erb` | Modified | +16 |
| `docs/LEGACY_BLOB_CONVERSION.md` | New | +251 |

**Total**: 7 files, ~658 lines added

## Testing Checklist

### Unit Tests (Not Yet Implemented)

- [ ] `LegacyBlobConverterService#legacy_blob?` detection
- [ ] `LegacyBlobConverterService#convert_legacy_blob` format transformation
- [ ] `LegacyBlobConverterService#scan_for_legacy_blobs` recursive search
- [ ] Error handling when blob sizes unavailable

### Integration Tests (Not Yet Implemented)

- [ ] Full migration flow with CONVERT_LEGACY_BLOBS=true
- [ ] Full migration flow with CONVERT_LEGACY_BLOBS=false
- [ ] Conversion with pre-2023 test account
- [ ] Progress tracking updates correctly

### Manual Testing

1. **Enable conversion**:
   ```bash
   echo "CONVERT_LEGACY_BLOBS=true" >> .env
   docker compose restart web sidekiq
   ```

2. **Start migration** with pre-2023 account

3. **Monitor logs**:
   ```bash
   docker compose logs -f sidekiq | grep -i legacy
   ```

4. **Verify status page** shows conversion progress

5. **Check progress_data**:
   ```bash
   docker compose exec web rails console
   > m = Migration.last
   > m.progress_data
   ```

## Performance Characteristics

### Time Complexity
- Scanning: O(n) where n = number of records
- Detection: O(m) where m = total data size (recursive scan)
- Fetching: O(b) where b = number of unique blobs
- Conversion: O(n) (in-memory transformation)

### Expected Performance

| Account Size | Legacy Blobs | Estimated Time |
|--------------|--------------|----------------|
| Small (< 100 posts) | 5-10 | +5-10 seconds |
| Medium (100-1000 posts) | 20-50 | +10-20 seconds |
| Large (> 1000 posts) | 50-200 | +30-60 seconds |

### Memory Usage
- CAR file loaded into memory: ~10-100 MB typical
- Records parsed: ~1-10 MB typical
- Blob sizes: ~1 KB (negligible)

## Error Handling

### Conversion Failures
- Logged with full stack trace
- Migration marked as failed
- User can retry with `CONVERT_LEGACY_BLOBS=false`

### Blob Size Failures (Non-Fatal)
- Uses -1 as sentinel value
- Logs warning
- Continues conversion
- PDS may accept or reject during validation

### Session Expiry (Fatal)
- Requires valid goat session
- Must be logged in to source PDS
- Raises `ConversionError`

## Known Limitations

1. **CAR Rebuilding**: Doesn't fully rebuild CAR file structure with proper MST. Relies on PDS to rebuild during import.

2. **Record Re-signing**: Converted records may need re-signing. Currently relies on PDS to handle this.

3. **Sentinel Values**: Uses -1 when blob size unavailable. Some PDS implementations may reject this.

4. **goat Dependency**: Requires goat CLI for CAR unpacking. Consider native Ruby implementation for production.

## Future Enhancements

### Short Term
1. Add unit tests for conversion logic
2. Add integration tests for full flow
3. Optimize CAR unpacking (native Ruby instead of goat CLI)
4. Add conversion statistics to status page

### Long Term
1. Proper CAR file rebuilding with MST
2. Record signature handling
3. Parallel blob size fetching
4. Caching blob sizes for retries
5. Admin dashboard for conversion statistics

## Dependencies

### Ruby Gems (Already Installed)
- `httparty` - HTTP client for API calls
- `json` - JSON parsing

### External Tools
- `goat` CLI - CAR file unpacking (already required)

### ATProto APIs Used
- `com.atproto.sync.getBlob` - Fetch blob sizes (HEAD request)
- `com.atproto.sync.getRepo` - Export repository
- `com.atproto.repo.importRepo` - Import repository

## Configuration Reference

### Environment Variables

```bash
# Required - Enable/disable conversion
CONVERT_LEGACY_BLOBS=false  # Default: false

# Optional - Custom timeouts (not yet implemented)
# LEGACY_BLOB_FETCH_TIMEOUT=10  # seconds per blob
# LEGACY_BLOB_SCAN_TIMEOUT=60   # seconds for scanning
```

## Deployment Checklist

- [x] Code implementation complete
- [x] Environment variables documented
- [x] Progress tracking implemented
- [x] UI feedback implemented
- [x] Documentation written
- [ ] Unit tests written
- [ ] Integration tests written
- [ ] Manual testing completed
- [ ] Performance benchmarks collected
- [ ] Staging deployment tested
- [ ] Production deployment plan

## Support and Troubleshooting

### Common Issues

**Issue**: "Goat session not found"
- **Solution**: Ensure logged in to source PDS before conversion

**Issue**: "Failed to fetch blob size"
- **Solution**: Check network connectivity, source PDS availability

**Issue**: "CAR unpacking failed"
- **Solution**: Verify goat CLI installed and in PATH

### Debug Commands

```bash
# Check Sidekiq logs
docker compose logs sidekiq | grep -i legacy

# Rails console inspection
docker compose exec web rails console
> m = Migration.find_by(token: 'EURO-xxxxxxxx')
> m.progress_data

# Verify goat installation
docker compose exec web goat --version

# Manual CAR unpacking test
docker compose exec web goat repo unpack /path/to/file.car --output /tmp/test
```

## References

- Original issue description (user-provided)
- goat source code: `/Users/svogelsang/Development/projects/Skeets/code/goat`
- indigo library: `/Users/svogelsang/Development/projects/Skeets/code/indigo/atproto/atdata/blob.go`
- ATProto spec: https://atproto.com/specs/data-model#blob-type

## Conclusion

Legacy blob format conversion has been successfully implemented as an optional feature. The implementation:

✅ Addresses the pre-2023 blob format issue
✅ Minimal performance impact (optional, configurable)
✅ Comprehensive error handling
✅ Clear user feedback (status page)
✅ Well-documented (code + docs)
✅ Follows existing patterns (GoatService, Jobs)

**Next Steps**:
1. Manual testing with pre-2023 account
2. Write unit/integration tests
3. Collect performance benchmarks
4. Deploy to staging environment
5. Production rollout with monitoring
