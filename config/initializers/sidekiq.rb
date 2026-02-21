# Be sure to restart your server when you modify this file.
#
# Sidekiq configuration for background job processing
#
# Configures both the client (job enqueueing) and server (job processing)

require 'sidekiq'
require 'sidekiq/api'
require 'sidekiq-scheduler'

# Determine Redis URL
redis_url = ENV['REDIS_URL'] || begin
  host = ENV['REDIS_HOST'] || 'localhost'
  port = ENV['REDIS_PORT'] || 6379
  password = ENV['REDIS_PASSWORD']
  db = ENV['REDIS_DB'] || 0

  if password.present?
    "redis://:#{password}@#{host}:#{port}/#{db}"
  else
    "redis://#{host}:#{port}/#{db}"
  end
end

# Sidekiq client configuration
sidekiq_config = {
  url: redis_url
}

# Configure Sidekiq client
Sidekiq.configure_client do |config|
  config.redis = sidekiq_config
end

# Configure Sidekiq server
Sidekiq.configure_server do |config|
  config.redis = sidekiq_config

  # Set concurrency based on environment.
  # Default 35 threads to support concurrent blob jobs + headroom
  # for non-blob jobs (account creation, repo import, prefs, etc.).
  config.concurrency = ENV['SIDEKIQ_CONCURRENCY']&.to_i || (Rails.env.test? ? 1 : 35)

  # Queue configuration is defined in the YAML config files:
  #   - config/sidekiq.yml: migrations, default, low queues
  #   - config/sidekiq_critical.yml: critical queue only (UpdatePlcJob, ActivateAccountJob)
  #
  # Do NOT set config.queues here — it would override the YAML for ALL
  # Sidekiq processes (both main and critical), breaking the queue separation.

  # Add middleware to handle deserialization errors gracefully
  config.server_middleware do |chain|
    chain.add(Class.new do
      def call(worker, job, queue)
        yield
      rescue ActiveJob::DeserializationError => e
        # If we can't deserialize the job arguments (e.g., a Migration was deleted),
        # log it and discard the job rather than retrying indefinitely
        Rails.logger.warn("[Sidekiq] Discarding job #{job['class']} due to deserialization error: #{e.message}")
        # Don't re-raise - this marks the job as successfully completed (but discarded)
      end
    end)
  end

  # Dead letter queue configuration
  config.death_handlers << ->(job, ex) do
    Rails.logger.error("Job failed: #{job['class']} - #{ex.message}")
  end
end

# Configure Active Job to use Sidekiq
Rails.application.config.active_job.queue_adapter = :sidekiq
