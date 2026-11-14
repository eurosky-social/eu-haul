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
# Usage:
#   result = SpaceTransferService.new(migration, goat: goat).transfer(goat.list_spaces(:old))
#   result.failed_blobs # => [{ 'space' => 'at://...', 'cid' => 'bafy...' }]
class SpaceTransferService
  BLOB_ATTEMPTS = 3

  Result = Struct.new(:spaces, :repos, :blobs, :failed_blobs, keyword_init: true)

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
        if move_blob(ref, cid)
          result.blobs += 1
        else
          result.failed_blobs << { 'space' => ref, 'cid' => cid }
        end
      end
    end

    logger.info("[Spaces] #{migration.token}: moved #{result.repos} repos and #{result.blobs} files" \
                "#{result.failed_blobs.any? ? ", #{result.failed_blobs.length} files failed" : ''}")
    result
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
    begin
      attempt += 1
      path = goat.download_space_blob(ref, cid)
      goat.upload_blob(path)
      true
    rescue GoatService::NetworkError, GoatService::TimeoutError => e
      if attempt < BLOB_ATTEMPTS
        pause(2**attempt)
        retry
      end
      logger.warn("[Spaces] #{migration.token}: file #{cid} in #{ref} failed after #{attempt} attempts: #{e.message}")
      false
    ensure
      FileUtils.rm_f(path) if path
    end
  end

  # All waits go through here so specs can stub them
  def pause(seconds)
    sleep(seconds)
  end
end
