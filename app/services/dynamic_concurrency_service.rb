# DynamicConcurrencyService - Controls how many heavy I/O migration jobs
# (blob downloads/uploads) can run concurrently.
#
# Since blob transfers stream to/from disk (never buffering full blobs in
# memory), the concurrency limit is based on network and PDS capacity rather
# than available RAM. The limit is a simple configurable value.
#
# Usage:
#   DynamicConcurrencyService.max_concurrent_heavy_io
#   # => 15 (default, configurable via MAX_CONCURRENT_BLOB_MIGRATIONS)

class DynamicConcurrencyService
  # Configurable concurrency limit for heavy I/O jobs.
  # Controls how many migrations can be in pending_download or pending_blobs
  # simultaneously. Tune based on network bandwidth and PDS rate limits.
  MAX_CONCURRENT = ENV.fetch('MAX_CONCURRENT_BLOB_MIGRATIONS', 15).to_i

  class << self
    # Returns the maximum number of heavy I/O jobs (blob downloads/uploads)
    # that should run concurrently.
    #
    # @return [Integer] Number of concurrent jobs allowed
    def max_concurrent_heavy_io
      MAX_CONCURRENT
    end

    # Kept for API compatibility. Same as max_concurrent_heavy_io since
    # there is no longer a cache to bypass.
    def max_concurrent_heavy_io!
      max_concurrent_heavy_io
    end

    # Returns diagnostic info about current concurrency state.
    # Useful for admin dashboards and debugging.
    #
    # @return [Hash] Concurrency diagnostics
    def diagnostics
      {
        max_concurrent: MAX_CONCURRENT,
        current_heavy_io_count: Migration.where(status: [:pending_download, :pending_blobs]).count
      }
    end
  end
end
