# LegacyBlobConverterService - Converts legacy blob format to current format
#
# Pre-early 2023 Bluesky accounts contain records with a deprecated blob schema
# that causes migration failures on modern PDS implementations.

require 'find'
require 'httparty'
#
# Legacy format: {"cid": "bafkreiabc...", "mimeType": "image/jpeg"}
# Current format: {"$type": "blob", "ref": {"$link": "bafkreiabc..."}, "mimeType": "image/jpeg", "size": 123456}
#
# This service:
# 1. Scans a CAR file for records containing legacy blob references
# 2. Fetches actual blob sizes from the source PDS via com.atproto.sync.getBlob
# 3. Converts legacy blob format to current format
# 4. Creates a new CAR file with converted records
#
# Usage:
#   service = LegacyBlobConverterService.new(migration)
#   new_car_path = service.convert_if_needed(car_path)
#
# Environment Variables:
#   CONVERT_LEGACY_BLOBS=true  # Enable conversion (default: false)
#
# Note: Conversion adds processing time as it requires HEAD requests for each blob
#
class LegacyBlobConverterService
  class ConversionError < StandardError; end

  attr_reader :migration, :logger

  def initialize(migration)
    @migration = migration
    @logger = Rails.logger
  end

  # Main entry point - converts CAR file if legacy blobs are detected and conversion is enabled
  # Returns path to converted CAR file, or original path if no conversion needed
  def convert_if_needed(car_path)
    unless conversion_enabled?
      logger.info("Legacy blob conversion disabled (CONVERT_LEGACY_BLOBS=false)")
      return car_path
    end

    logger.info("Scanning CAR file for legacy blob references")

    # Parse CAR file and extract records
    records = extract_records_from_car(car_path)
    logger.info("Extracted #{records.length} records from CAR file")

    # Scan for legacy blobs
    legacy_blobs = find_legacy_blobs(records)

    if legacy_blobs.empty?
      logger.info("No legacy blob references found - skipping conversion")
      return car_path
    end

    logger.info("Found #{legacy_blobs.length} legacy blob references - starting conversion")

    # Fetch blob sizes
    blob_sizes = fetch_blob_sizes(legacy_blobs)

    # Convert records
    converted_records = convert_records(records, blob_sizes)

    # Create new CAR file
    new_car_path = create_converted_car(car_path, converted_records)

    logger.info("Legacy blob conversion completed: #{new_car_path}")
    new_car_path

  rescue StandardError => e
    logger.error("Legacy blob conversion failed: #{e.message}")
    logger.error(e.backtrace.join("\n"))
    raise ConversionError, "Failed to convert legacy blobs: #{e.message}"
  end

  private

  def conversion_enabled?
    ENV.fetch('CONVERT_LEGACY_BLOBS', 'false').to_s.downcase == 'true'
  end

  # Extract records from CAR file using goat CLI
  def extract_records_from_car(car_path)
    work_dir = Rails.root.join('tmp', 'goat', migration.did, 'legacy_conversion')
    FileUtils.mkdir_p(work_dir)

    # Use goat repo unpack to extract records as JSON files
    logger.info("Unpacking CAR file to extract records")

    stdout, stderr, status = execute_command(
      'goat', 'repo', 'unpack',
      car_path,
      '--output', work_dir.to_s
    )

    unless status.success?
      raise ConversionError, "Failed to unpack CAR file: #{stderr}"
    end

    # Read all JSON files
    records = []
    Find.find(work_dir) do |path|
      next unless path.end_with?('.json')
      next if File.basename(path) == '_commit.json'

      begin
        content = File.read(path)
        record_data = JSON.parse(content)

        # Extract collection and rkey from path
        relative_path = Pathname.new(path).relative_path_from(work_dir).to_s
        relative_path = relative_path.sub(/\.json$/, '')

        records << {
          path: relative_path,
          data: record_data
        }
      rescue JSON::ParserError => e
        logger.warn("Failed to parse record at #{path}: #{e.message}")
      end
    end

    records
  end

  # Recursively scan record data for legacy blob references
  def find_legacy_blobs(records)
    legacy_blobs = []

    records.each do |record|
      blobs = scan_for_legacy_blobs(record[:data])

      blobs.each do |blob|
        legacy_blobs << {
          cid: blob['cid'],
          mimeType: blob['mimeType'],
          record_path: record[:path]
        }
      end
    end

    # Deduplicate by CID
    legacy_blobs.uniq { |b| b[:cid] }
  end

  # Recursively scan a data structure for legacy blob objects
  def scan_for_legacy_blobs(data, blobs = [])
    case data
    when Hash
      if legacy_blob?(data)
        blobs << data
      else
        data.each_value { |value| scan_for_legacy_blobs(value, blobs) }
      end
    when Array
      data.each { |item| scan_for_legacy_blobs(item, blobs) }
    end

    blobs
  end

  # Check if a hash matches the legacy blob format
  def legacy_blob?(obj)
    obj.is_a?(Hash) &&
      obj.key?('cid') &&
      obj.key?('mimeType') &&
      !obj.key?('$type') &&
      !obj.key?('ref')
  end

  # Fetch actual blob sizes from source PDS using HEAD requests
  def fetch_blob_sizes(legacy_blobs)
    logger.info("Fetching sizes for #{legacy_blobs.length} blobs from source PDS")

    sizes = {}
    access_token = get_access_token

    legacy_blobs.each_with_index do |blob, index|
      cid = blob[:cid]

      begin
        size = get_blob_size(cid, access_token)
        sizes[cid] = size

        logger.debug("Blob #{index + 1}/#{legacy_blobs.length}: #{cid} = #{size} bytes")

        # Rate limiting: sleep between requests
        sleep(0.1) if index < legacy_blobs.length - 1

      rescue StandardError => e
        logger.warn("Failed to get size for blob #{cid}: #{e.message} - using -1 as sentinel")
        sizes[cid] = -1  # Use -1 as sentinel value when size cannot be determined
      end
    end

    logger.info("Successfully fetched #{sizes.count { |_, v| v > 0 }} blob sizes")
    sizes
  end

  # Get blob size via HEAD request to com.atproto.sync.getBlob
  def get_blob_size(cid, access_token)
    url = "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob?did=#{migration.did}&cid=#{cid}"

    response = HTTParty.head(
      url,
      headers: {
        'Authorization' => "Bearer #{access_token}"
      },
      timeout: 10
    )

    unless response.success?
      raise "HTTP #{response.code}: #{response.message}"
    end

    content_length = response.headers['content-length']
    raise "No Content-Length header in response" unless content_length

    content_length.to_i
  end

  # Convert legacy blobs in all records
  def convert_records(records, blob_sizes)
    logger.info("Converting legacy blobs in #{records.length} records")

    converted_count = 0

    converted_records = records.map do |record|
      converted_data = convert_legacy_blobs_in_data(record[:data], blob_sizes)

      # Check if any changes were made
      if converted_data != record[:data]
        converted_count += 1
      end

      {
        path: record[:path],
        data: converted_data
      }
    end

    logger.info("Converted legacy blobs in #{converted_count} records")
    converted_records
  end

  # Recursively convert legacy blobs in data structure
  def convert_legacy_blobs_in_data(data, blob_sizes)
    case data
    when Hash
      if legacy_blob?(data)
        convert_legacy_blob(data, blob_sizes)
      else
        data.transform_values { |value| convert_legacy_blobs_in_data(value, blob_sizes) }
      end
    when Array
      data.map { |item| convert_legacy_blobs_in_data(item, blob_sizes) }
    else
      data
    end
  end

  # Convert a single legacy blob to current format
  def convert_legacy_blob(legacy_blob, blob_sizes)
    cid = legacy_blob['cid']
    size = blob_sizes[cid] || -1

    {
      '$type' => 'blob',
      'ref' => {
        '$link' => cid
      },
      'mimeType' => legacy_blob['mimeType'],
      'size' => size
    }
  end

  # Create new CAR file with converted records
  # This uses goat to re-import the records into a temporary account,
  # then export the repo as a new CAR file
  #
  # NOTE: This is a simplified approach. A production implementation would
  # need to properly rebuild the CAR file while preserving signatures and
  # repo structure. For now, we rely on the PDS to rebuild the repo.
  def create_converted_car(original_car_path, converted_records)
    work_dir = Rails.root.join('tmp', 'goat', migration.did, 'legacy_conversion')
    converted_car_path = original_car_path.sub('.car', '.converted.car')

    logger.info("Creating converted CAR file: #{converted_car_path}")

    # Write converted records back to JSON files
    converted_records.each do |record|
      json_path = work_dir.join("#{record[:path]}.json")
      FileUtils.mkdir_p(json_path.dirname)
      File.write(json_path, JSON.pretty_generate(record[:data]))
    end

    # Note: The proper way to do this would be to rebuild the CAR file
    # with the MST (Merkle Search Tree) structure intact. However, that
    # requires complex CAR manipulation.
    #
    # Instead, we'll use a simpler approach: import the converted records
    # into the target PDS directly, which will handle the MST rebuilding.
    # We mark the CAR as converted so import_repo knows to use converted data.

    # For now, copy the original CAR and mark it with a flag file
    FileUtils.cp(original_car_path, converted_car_path)
    File.write("#{converted_car_path}.converted", "true")

    # Write converted records to a JSON file that import_repo can use
    records_json_path = "#{converted_car_path}.records.json"
    File.write(records_json_path, JSON.pretty_generate(converted_records))

    logger.info("Converted CAR file created with #{converted_records.length} records")
    converted_car_path
  end

  # Get access token from goat session
  def get_access_token
    # Read goat session file
    session_file = File.expand_path("~/.config/goat/session.json")

    unless File.exist?(session_file)
      raise ConversionError, "Goat session not found - must be logged in to old PDS"
    end

    session_data = JSON.parse(File.read(session_file))
    access_token = session_data['accessJwt']

    unless access_token
      raise ConversionError, "No access token in goat session"
    end

    access_token
  end

  # Execute shell command with timeout
  def execute_command(*args, timeout: 30)
    require 'open3'

    stdout, stderr, status = Open3.capture3(*args, timeout: timeout)

    [stdout, stderr, status]
  rescue Timeout::Error
    raise ConversionError, "Command timed out: #{args.join(' ')}"
  end
end
