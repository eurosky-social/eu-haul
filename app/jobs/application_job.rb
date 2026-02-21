class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Silently discard jobs whose Migration record has been deleted.
  # This happens when stale jobs (e.g. mailer notifications) remain in the
  # Sidekiq queue after a migration is cleaned up or the DB is reset.
  discard_on ActiveJob::DeserializationError
end
