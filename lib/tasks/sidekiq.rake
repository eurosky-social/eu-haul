namespace :sidekiq do
  desc "Show Sidekiq global stats"
  task status: :environment do
    stats = Sidekiq::Stats.new

    puts "Sidekiq Status"
    puts "=" * 40
    puts "Processed:  #{stats.processed}"
    puts "Failed:     #{stats.failed}"
    puts "Enqueued:   #{stats.enqueued}"
    puts "Scheduled:  #{stats.scheduled_size}"
    puts "Retries:    #{stats.retry_size}"
    puts "Dead:       #{stats.dead_size}"
    puts "Workers:    #{stats.workers_size}"
    puts "Processes:  #{stats.processes_size}"
  end

  desc "Show queue sizes"
  task queues: :environment do
    queues = Sidekiq::Queue.all

    if queues.empty?
      puts "No queues found."
      next
    end

    puts "Sidekiq Queues"
    puts "=" * 40

    queues.each do |queue|
      latency = queue.latency.round(1)
      puts "%-20s %5d jobs  (latency: %ss)" % [queue.name, queue.size, latency]
    end
  end

  desc "Show currently running workers"
  task workers: :environment do
    workers = Sidekiq::Workers.new

    if workers.size.zero?
      puts "No workers currently running."
      next
    end

    puts "Running Workers (#{workers.size})"
    puts "=" * 40

    workers.each do |process_id, thread_id, work|
      payload = work["payload"]
      elapsed = Time.now - Time.at(work["run_at"])
      minutes = (elapsed / 60).floor
      seconds = (elapsed % 60).floor

      puts "#{payload['class']}"
      puts "  Queue:   #{work['queue']}"
      puts "  Args:    #{payload['args']&.inspect&.truncate(80)}"
      puts "  Running: #{minutes}m #{seconds}s"
      puts ""
    end
  end

  desc "Show jobs in the retry set"
  task retries: :environment do
    retries = Sidekiq::RetrySet.new

    if retries.size.zero?
      puts "No retries pending."
      next
    end

    puts "Retry Set (#{retries.size})"
    puts "=" * 40

    retries.each do |job|
      puts "#{job.klass}"
      puts "  Queue:      #{job.queue}"
      puts "  Error:      #{job.error_class}: #{job.error_message&.truncate(80)}"
      puts "  Retries:    #{job['retry_count']}"
      puts "  Next retry: #{job.at&.strftime('%Y-%m-%d %H:%M:%S')}"
      puts ""
    end
  end

  desc "Show dead (permanently failed) jobs"
  task dead: :environment do
    dead = Sidekiq::DeadSet.new

    if dead.size.zero?
      puts "No dead jobs."
      next
    end

    puts "Dead Set (#{dead.size})"
    puts "=" * 40

    dead.each do |job|
      puts "#{job.klass}"
      puts "  Queue:  #{job.queue}"
      puts "  Error:  #{job.error_class}: #{job.error_message&.truncate(80)}"
      puts "  Died:   #{job.at&.strftime('%Y-%m-%d %H:%M:%S')}"
      puts ""
    end
  end

  desc "Show active migrations and their progress"
  task migrations: :environment do
    active = Migration.where.not(status: %w[completed failed expired])
                      .order(created_at: :desc)

    if active.empty?
      puts "No active migrations."
      next
    end

    puts "Active Migrations (#{active.count})"
    puts "=" * 40

    active.each do |m|
      puts "#{m.token} (#{m.status})"
      puts "  DID:      #{m.did || 'not yet assigned'}"
      puts "  Handle:   #{m.old_handle}"
      puts "  Progress: #{m.progress_percentage}%"
      puts "  Started:  #{m.created_at.strftime('%Y-%m-%d %H:%M:%S')}"
      puts "  Updated:  #{m.updated_at.strftime('%Y-%m-%d %H:%M:%S')}"
      puts "  Error:    #{m.last_error.truncate(80)}" if m.last_error.present?
      puts ""
    end
  end

  desc "Show full Sidekiq dashboard (all of the above)"
  task dashboard: :environment do
    %w[status queues workers migrations retries dead].each do |task|
      Rake::Task["sidekiq:#{task}"].invoke
      puts ""
    end
  end
end
