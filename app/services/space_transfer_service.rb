# SpaceTransferService - moves an account's atproto spaces to the new PDS
#
# Spaces are permissioned data (private posts, groups, gated content, ...).
# They live outside the public repo, so the repo and blob stages don't carry
# them. Per the spaces spec ("Account migration"), for the spaces listed on
# the old PDS:
#
#   1. Settings ("space meta") of every space the account runs - policy,
#      member list, writer set. These must exist on the new PDS before any
#      repo in the space is imported there.
#   2. Per space, the account's own repo in it.
#   3. Per space, the files that repo references. Only after step 2: the new
#      PDS keeps an uploaded file only if a record already references it.
#
# Importing again replaces what the new PDS holds for that space, so a
# second run (the re-sync before activation) is safe.
#
# The new PDS may cap uploads per account (bsky.social: 1,000 files a day),
# and space files count against that like public ones. When it refuses until
# a reset hours away, the remaining space files are downloaded but not sent,
# and wait in files_dir for the RetryFailedBlobsJob pass at the reset. Only
# the account's old session can download a space file, and by then it may be
# gone. The CIDs the new PDS already has are listed in sent_ledger, so a later
# run (the re-sync, a retry pass) doesn't spend the quota on them again.
#
# Usage:
#   result = SpaceTransferService.new(migration, goat: goat).transfer(goat.list_spaces(:old))
#   result.failed_blobs # => [{ 'space' => 'at://...', 'cid' => 'bafy...' }]
#   result.quota_error  # => the GoatService::QuotaExhaustedError, or nil
class SpaceTransferService
  BLOB_ATTEMPTS = 3

  Result = Struct.new(:spaces, :repos, :blobs, :failed_blobs, :quota_error, keyword_init: true)

  # Where a migration's space files are downloaded to (GoatService saves them
  # there) and kept while they wait for the quota. It is on the tmp volume the
  # web and Sidekiq containers share, so it outlasts a job and a redeploy.
  def self.files_dir(migration)
    Rails.root.join('tmp', 'goat', migration.did, 'space_blobs')
  end

  # CIDs of the space files the new PDS already has, one per line
  def self.sent_ledger(migration)
    files_dir(migration).join('sent.txt')
  end

  attr_reader :migration, :goat, :logger

  def initialize(migration, goat: GoatService.new(migration), logger: Rails.logger)
    @migration = migration
    @goat = goat
    @logger = logger
  end

  # spaces: listSpaces entries from the old PDS ({ 'space' => 'at://...' }).
  # Raises GoatService::SpaceImportRejectedError when the new PDS refuses a
  # space's data, and the usual GoatService errors when a call keeps failing.
  # Files that keep failing are reported in the result, not raised.
  def transfer(spaces)
    refs = spaces.map { |entry| entry['space'] }.compact.uniq
    result = Result.new(spaces: refs.length, repos: 0, blobs: 0, failed_blobs: [])
    return result if refs.empty?

    own, others = refs.partition { |ref| GoatService.space_authority(ref) == migration.did }
    logger.info("[Spaces] #{migration.token}: #{refs.length} spaces, #{own.length} run by the account")

    own.each { |ref| move_settings(ref) }

    # The account's own spaces first: their settings are already in place
    (own + others).each do |ref|
      next unless move_repo(ref)

      result.repos += 1
      goat.list_space_blobs(ref).each do |cid|
        if sent?(cid)
          # An earlier run sent it
          result.blobs += 1
        elsif @quota_error
          # The new PDS refuses uploads until its quota comes back. Keep a
          # copy for the pass at the reset, and keep moving the repos, which
          # don't count against the quota.
          keep_copy(ref, cid)
          result.failed_blobs << { 'space' => ref, 'cid' => cid }
        elsif move_blob(ref, cid)
          result.blobs += 1
        else
          result.failed_blobs << { 'space' => ref, 'cid' => cid }
        end
      end
    end

    result.quota_error = @quota_error
    logger.info("[Spaces] #{migration.token}: moved #{result.repos} repos and #{result.blobs} files" \
                "#{result.failed_blobs.any? ? ", #{result.failed_blobs.length} files not sent" : ''}")
    result
  end

  # Uploads the space files an earlier run left over (entries as in
  # Result#failed_blobs), from the kept copy, or downloaded again while the
  # old session still works. One attempt each: RetryFailedBlobsJob's passes
  # try again. Stops at the upload quota.
  # Returns [the entries still missing, the QuotaExhaustedError or nil].
  def send_left_over(entries)
    still_missing = []
    entries.each do |entry|
      next if sent?(entry['cid'])

      still_missing << entry if @quota_error || !send_left_over_file(entry['space'], entry['cid'])
    end
    [still_missing, @quota_error]
  end

  private

  def move_settings(ref)
    path = goat.export_space_meta(ref)
    goat.import_space_meta(path)
  ensure
    FileUtils.rm_f(path) if path
  end

  # false when the account has no repo of its own in the space
  def move_repo(ref)
    path = goat.export_space_repo(ref)
    return false unless path

    goat.import_space_repo(path)
    true
  ensure
    FileUtils.rm_f(path) if path
  end

  # A file that keeps failing must not stop the other spaces; the re-sync
  # before activation tries it again.
  def move_blob(ref, cid)
    attempt = 0
    keep = false
    begin
      attempt += 1
      path = goat.download_space_blob(ref, cid)
      goat.upload_blob(path)
      mark_sent(cid)
      true
    rescue GoatService::QuotaExhaustedError => e
      # Every retry before the reset is refused too. The pass at the reset
      # uploads this copy.
      note_quota(e)
      keep = true
      false
    rescue GoatService::NetworkError, GoatService::TimeoutError => e
      if attempt < BLOB_ATTEMPTS
        pause(2**attempt)
        retry
      end
      logger.warn("[Spaces] #{migration.token}: file #{cid} in #{ref} failed after #{attempt} attempts: #{e.message}")
      false
    ensure
      FileUtils.rm_f(path) if path && !keep
    end
  end

  # true when the file reached the new PDS
  def send_left_over_file(ref, cid)
    path = local_copy(cid)
    path = goat.download_space_blob(ref, cid) unless File.file?(path)
    goat.upload_blob(path)
    mark_sent(cid)
    FileUtils.rm_f(path)
    true
  rescue GoatService::QuotaExhaustedError => e
    note_quota(e)
    false
  rescue StandardError => e
    logger.warn("[Spaces] #{migration.token}: left-over file #{cid} in #{ref} not sent: #{e.message}")
    false
  end

  # Downloads a file the quota stopped, so the pass at the reset can send it
  # without the old session. A failed download is retried by that pass while
  # the old session still works.
  def keep_copy(ref, cid)
    return if File.file?(local_copy(cid))

    goat.download_space_blob(ref, cid)
  rescue StandardError => e
    logger.warn("[Spaces] #{migration.token}: could not keep a copy of file #{cid} in #{ref}: #{e.message}")
  end

  def note_quota(error)
    @quota_error = error
    logger.warn("[Spaces] #{migration.token}: the new PDS refuses uploads until " \
                "#{error.reset_at&.utc&.iso8601}; keeping the remaining space files for then")
  end

  def local_copy(cid)
    self.class.files_dir(migration).join(cid).to_s
  end

  def sent?(cid)
    sent_cids.include?(cid)
  end

  def mark_sent(cid)
    ledger = self.class.sent_ledger(migration)
    FileUtils.mkdir_p(ledger.dirname)
    File.open(ledger, 'a') { |file| file.puts(cid) }
    sent_cids << cid
  end

  def sent_cids
    @sent_cids ||= begin
      ledger = self.class.sent_ledger(migration)
      File.file?(ledger) ? File.readlines(ledger, chomp: true).to_set : Set.new
    end
  end

  # All waits go through here so specs can stub them
  def pause(seconds)
    sleep(seconds)
  end
end
