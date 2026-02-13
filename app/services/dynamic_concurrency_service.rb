# DynamicConcurrencyService - Calculates how many heavy I/O migration jobs
# can run concurrently based on available system memory.
#
# Instead of a fixed concurrency limit, this service reads actual available
# memory and dynamically sizes the pool. On a 256GB machine with low load,
# many more blob jobs can run than on a busy 16GB machine.
#
# Memory model per blob job:
#   - 10 parallel threads, each holding 1 blob in memory
#   - Worst case: 10 x 100MB = 1GB (all max-size blobs, extremely rare)
#   - Typical case: 10 x 5MB = 50MB (average image blobs)
#   - Conservative estimate used: 300MB per job (covers Ruby overhead + spikes)
#
# Memory sources (checked in order):
#   1. cgroup v2 (Docker containers with memory limits)
#   2. cgroup v1 (older Docker)
#   3. /proc/meminfo MemAvailable (Linux host or container)
#   4. Static fallback (macOS development, default 8)
#
# Results are cached for 30 seconds to avoid excessive filesystem reads.
#
# Usage:
#   DynamicConcurrencyService.max_concurrent_heavy_io
#   # => 12 (based on current available memory)

class DynamicConcurrencyService
  # Per-job memory budget (conservative estimate in MB).
  # Accounts for: 10 threads x blob data + Ruby thread overhead + HTTP buffers
  MEMORY_PER_JOB_MB = ENV.fetch('MEMORY_PER_BLOB_JOB_MB', 300).to_i

  # Memory reserved for system processes: OS, Rails web, Sidekiq, PostgreSQL, Redis
  MEMORY_RESERVE_MB = ENV.fetch('MEMORY_RESERVE_MB', 4096).to_i

  # Hard floor and ceiling regardless of available memory
  MIN_CONCURRENT = ENV.fetch('MIN_CONCURRENT_BLOB_MIGRATIONS', 4).to_i
  MAX_CONCURRENT = ENV.fetch('MAX_CONCURRENT_BLOB_MIGRATIONS', 30).to_i

  # Cache duration for memory readings
  CACHE_TTL = 30.seconds

  class << self
    # Returns the maximum number of heavy I/O jobs (blob downloads/uploads)
    # that should run concurrently based on current available memory.
    #
    # @return [Integer] Number of concurrent jobs allowed (clamped between MIN and MAX)
    def max_concurrent_heavy_io
      Rails.cache.fetch('dynamic_concurrency:max_heavy_io', expires_in: CACHE_TTL) do
        calculate_max_concurrent
      end
    end

    # Force recalculation (bypasses cache). Useful for testing or after
    # significant memory changes.
    def max_concurrent_heavy_io!
      Rails.cache.delete('dynamic_concurrency:max_heavy_io')
      max_concurrent_heavy_io
    end

    # Returns diagnostic info about current memory state.
    # Useful for admin dashboards and debugging.
    #
    # @return [Hash] Memory diagnostics
    def diagnostics
      available = available_memory_mb
      computed = available ? ((available - MEMORY_RESERVE_MB) / MEMORY_PER_JOB_MB).floor : nil

      {
        available_memory_mb: available,
        memory_source: memory_source,
        memory_reserve_mb: MEMORY_RESERVE_MB,
        memory_per_job_mb: MEMORY_PER_JOB_MB,
        computed_max: computed,
        clamped_max: max_concurrent_heavy_io,
        min_concurrent: MIN_CONCURRENT,
        max_concurrent: MAX_CONCURRENT,
        current_heavy_io_count: Migration.where(status: [:pending_download, :pending_blobs]).count
      }
    end

    private

    def calculate_max_concurrent
      available = available_memory_mb

      unless available
        Rails.logger.info("[DynamicConcurrency] Could not read system memory, using fallback: #{fallback_limit}")
        return fallback_limit
      end

      usable = available - MEMORY_RESERVE_MB

      if usable <= 0
        Rails.logger.warn("[DynamicConcurrency] Available memory (#{available}MB) below reserve (#{MEMORY_RESERVE_MB}MB), using minimum: #{MIN_CONCURRENT}")
        return MIN_CONCURRENT
      end

      computed = (usable / MEMORY_PER_JOB_MB).floor
      result = computed.clamp(MIN_CONCURRENT, MAX_CONCURRENT)

      Rails.logger.info(
        "[DynamicConcurrency] Available: #{available}MB, usable: #{usable}MB, " \
        "per_job: #{MEMORY_PER_JOB_MB}MB, computed: #{computed}, result: #{result} " \
        "(source: #{memory_source})"
      )

      result
    end

    # Returns available memory in MB, trying multiple sources.
    # Returns nil if unable to determine.
    def available_memory_mb
      read_cgroup_v2_available || read_cgroup_v1_available || read_proc_meminfo || nil
    end

    # Identifies which memory source is being used (for diagnostics)
    def memory_source
      if cgroup_v2_available?
        'cgroup_v2'
      elsif cgroup_v1_available?
        'cgroup_v1'
      elsif proc_meminfo_available?
        'proc_meminfo'
      else
        'fallback'
      end
    end

    # cgroup v2: /sys/fs/cgroup/memory.max and memory.current
    # Used in modern Docker containers with memory limits
    def read_cgroup_v2_available
      return nil unless cgroup_v2_available?

      max_bytes = File.read('/sys/fs/cgroup/memory.max').strip
      return nil if max_bytes == 'max' # No limit set

      max_mb = max_bytes.to_i / (1024 * 1024)
      current_mb = File.read('/sys/fs/cgroup/memory.current').strip.to_i / (1024 * 1024)

      max_mb - current_mb
    rescue StandardError => e
      Rails.logger.debug("[DynamicConcurrency] cgroup v2 read failed: #{e.message}")
      nil
    end

    # cgroup v1: /sys/fs/cgroup/memory/memory.limit_in_bytes and memory.usage_in_bytes
    def read_cgroup_v1_available
      return nil unless cgroup_v1_available?

      limit = File.read('/sys/fs/cgroup/memory/memory.limit_in_bytes').strip.to_i
      # Very large values mean "no limit" (often 2^63 or similar)
      return nil if limit > 1_000_000_000_000_000

      usage = File.read('/sys/fs/cgroup/memory/memory.usage_in_bytes').strip.to_i
      (limit - usage) / (1024 * 1024)
    rescue StandardError => e
      Rails.logger.debug("[DynamicConcurrency] cgroup v1 read failed: #{e.message}")
      nil
    end

    # /proc/meminfo MemAvailable — kernel's estimate of memory available
    # for new applications without swapping.
    def read_proc_meminfo
      return nil unless proc_meminfo_available?

      content = File.read('/proc/meminfo')
      match = content.match(/MemAvailable:\s+(\d+)\s+kB/)
      return nil unless match

      match[1].to_i / 1024 # Convert KB to MB
    rescue StandardError => e
      Rails.logger.debug("[DynamicConcurrency] /proc/meminfo read failed: #{e.message}")
      nil
    end

    def cgroup_v2_available?
      File.exist?('/sys/fs/cgroup/memory.max') && File.exist?('/sys/fs/cgroup/memory.current')
    end

    def cgroup_v1_available?
      File.exist?('/sys/fs/cgroup/memory/memory.limit_in_bytes')
    end

    def proc_meminfo_available?
      File.exist?('/proc/meminfo')
    end

    # Static fallback when running on macOS (development) or when
    # memory detection fails. Uses the env var or default of 8.
    def fallback_limit
      ENV.fetch('MAX_CONCURRENT_BLOB_MIGRATIONS', 8).to_i.clamp(MIN_CONCURRENT, MAX_CONCURRENT)
    end
  end
end
