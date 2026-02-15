require 'test_helper'

# Test concurrent GoatService work directory isolation
# This test verifies that multiple GoatService instances can run simultaneously
# without interfering with each other's temporary files.
#
# Background:
# GoatService stores temporary files (CAR exports, blobs, preferences, PLC operations)
# in per-migration work directories under tmp/goat/<did>/. This ensures that concurrent
# migrations don't overwrite each other's files.
#
class GoatServiceConcurrencyTest < ActiveSupport::TestCase
  def setup
    # Use unique DIDs per test run to avoid parallel test processes sharing work directories
    @unique_suffix = SecureRandom.hex(8)
    @migration1 = Migration.create!(
      did: "did:plc:conc1#{@unique_suffix}",
      old_handle: 'user1.old-pds.example',
      new_handle: 'user1.new-pds.example',
      old_pds_host: 'https://old-pds.example',
      new_pds_host: 'https://new-pds.example',
      email: 'user1@example.com',
      email_verified_at: Time.current
    )

    @migration2 = Migration.create!(
      did: "did:plc:conc2#{@unique_suffix}",
      old_handle: 'user2.old-pds.example',
      new_handle: 'user2.new-pds.example',
      old_pds_host: 'https://old-pds.example',
      new_pds_host: 'https://new-pds.example',
      email: 'user2@example.com',
      email_verified_at: Time.current
    )

    @service1 = GoatService.new(@migration1)
    @service2 = GoatService.new(@migration2)
  end

  def teardown
    @service1.cleanup if @service1
    @service2.cleanup if @service2
  end

  test "each migration gets isolated work directory" do
    assert_not_equal @service1.work_dir, @service2.work_dir
    assert_includes @service1.work_dir.to_s, @migration1.did
    assert_includes @service2.work_dir.to_s, @migration2.did
  end

  test "work directories are created on initialization" do
    assert Dir.exist?(@service1.work_dir)
    assert Dir.exist?(@service2.work_dir)
  end

  test "cleanup removes work directory" do
    # Create some temp files like the service would during a migration
    blobs_dir = @service1.work_dir.join('blobs')
    FileUtils.mkdir_p(blobs_dir)
    File.write(@service1.work_dir.join('account.123.car'), 'fake car data')
    File.write(@service1.work_dir.join('prefs.json'), '{"preferences":[]}')
    File.write(blobs_dir.join('bafyabc123'), 'fake blob data')

    assert File.exist?(@service1.work_dir.join('account.123.car'))

    @service1.cleanup

    assert_not File.exist?(@service1.work_dir)
  end

  test "cleanup of one migration does not affect another" do
    # Write files in both work directories
    File.write(@service1.work_dir.join('account.1.car'), 'migration 1 data')
    File.write(@service2.work_dir.join('account.2.car'), 'migration 2 data')

    # Cleanup migration 1
    @service1.cleanup

    # Migration 2's files should be untouched
    assert File.exist?(@service2.work_dir.join('account.2.car'))
    assert_equal 'migration 2 data', File.read(@service2.work_dir.join('account.2.car'))
  end

  test "five concurrent migrations maintain work directory isolation" do
    extra_migrations = 3.times.map do |i|
      Migration.create!(
        did: "did:plc:concurrent#{(i + 3).to_s.rjust(16, '0')}",
        old_handle: "user#{i + 3}.old-pds.example",
        new_handle: "user#{i + 3}.new-pds.example",
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: "user#{i + 3}@example.com",
        email_verified_at: Time.current
      )
    end

    all_migrations = [@migration1, @migration2] + extra_migrations
    services = all_migrations.map { |m| GoatService.new(m) }

    begin
      # All work directories should be unique
      work_dirs = services.map(&:work_dir)
      assert_equal 5, work_dirs.uniq.size, "All work directories should be unique"

      # Each work directory should contain its migration DID
      services.each_with_index do |service, index|
        assert_includes service.work_dir.to_s, all_migrations[index].did
      end
    ensure
      services[2..4].each(&:cleanup)
    end
  end

  test "concurrent file operations in isolated work directories" do
    migrations = 4.times.map do |i|
      Migration.create!(
        did: "did:plc:fileops#{i.to_s.rjust(18, '0')}",
        old_handle: "fileops#{i}.old-pds.example",
        new_handle: "fileops#{i}.new-pds.example",
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: "fileops#{i}@example.com",
        email_verified_at: Time.current
      )
    end

    services = migrations.map { |m| GoatService.new(m) }

    begin
      # Concurrently create temp files (simulating parallel migrations)
      threads = services.map.with_index do |service, index|
        Thread.new do
          # Simulate writing a CAR file
          car_file = service.work_dir.join("account.#{Time.now.to_i}.car")
          File.write(car_file, "car data for migration #{index}")

          # Simulate writing blobs
          blobs_dir = service.work_dir.join('blobs')
          FileUtils.mkdir_p(blobs_dir)
          3.times do |b|
            File.write(blobs_dir.join("blob_#{b}"), "blob #{b} for migration #{index}")
          end

          # Simulate writing preferences
          prefs_file = service.work_dir.join('prefs.json')
          File.write(prefs_file, { migration_index: index }.to_json)

          sleep(rand * 0.05)

          # Verify our files weren't overwritten by another migration
          prefs = JSON.parse(File.read(prefs_file))
          prefs['migration_index']
        end
      end

      results = threads.map(&:value)

      # Each migration should have read back its own data
      results.each_with_index do |migration_index, expected_index|
        assert_equal expected_index, migration_index,
          "Migration #{expected_index} should read back its own preferences"
      end
    ensure
      services.each(&:cleanup)
    end
  end

  test "concurrent cleanup operations do not interfere" do
    migrations = 5.times.map do |i|
      Migration.create!(
        did: "did:plc:cleanup#{i.to_s.rjust(18, '0')}",
        old_handle: "cleanup#{i}.old-pds.example",
        new_handle: "cleanup#{i}.new-pds.example",
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: "cleanup#{i}@example.com",
        email_verified_at: Time.current
      )
    end

    services = migrations.map { |m| GoatService.new(m) }

    # Create files in each work directory
    services.each_with_index do |service, index|
      blobs_dir = service.work_dir.join('blobs')
      FileUtils.mkdir_p(blobs_dir)
      File.write(service.work_dir.join('account.car'), "data #{index}")
      File.write(blobs_dir.join('blob1'), "blob #{index}")
    end

    # Verify all directories exist
    services.each { |s| assert Dir.exist?(s.work_dir) }

    # Concurrently cleanup all services
    threads = services.map do |service|
      Thread.new do
        sleep(rand * 0.02)
        service.cleanup
        !File.exist?(service.work_dir)
      end
    end

    results = threads.map(&:value)

    assert results.all?, "All cleanup operations should succeed"

    services.each do |service|
      assert_not File.exist?(service.work_dir), "Work directory should be removed"
    end
  end
end
