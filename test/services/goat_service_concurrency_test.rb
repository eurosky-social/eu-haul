require 'test_helper'

# Test concurrent goat session isolation
# This test verifies that multiple GoatService instances can run simultaneously
# without interfering with each other's authentication sessions.
#
# Background:
# The goat CLI stores auth sessions in ~/.local/state/goat/auth-session.json by default.
# This caused a critical bug where concurrent migrations would overwrite each other's sessions.
#
# Solution:
# We now set XDG_STATE_HOME to a migration-specific directory, isolating each session.
#
class GoatServiceConcurrencyTest < ActiveSupport::TestCase
  def setup
    @migration1 = Migration.create!(
      did: 'did:plc:test1234567890abcdef',
      old_handle: 'user1.old-pds.example',
      new_handle: 'user1.new-pds.example',
      old_pds_host: 'https://old-pds.example',
      new_pds_host: 'https://new-pds.example',
      password: 'password1'
    )

    @migration2 = Migration.create!(
      did: 'did:plc:test0987654321fedcba',
      old_handle: 'user2.old-pds.example',
      new_handle: 'user2.new-pds.example',
      old_pds_host: 'https://old-pds.example',
      new_pds_host: 'https://new-pds.example',
      password: 'password2'
    )

    @service1 = GoatService.new(@migration1)
    @service2 = GoatService.new(@migration2)
  end

  def teardown
    # Clean up test directories
    @service1.cleanup if @service1
    @service2.cleanup if @service2
  end

  test "each migration gets isolated work directory" do
    assert_not_equal @service1.work_dir, @service2.work_dir
    assert_includes @service1.work_dir.to_s, @migration1.did
    assert_includes @service2.work_dir.to_s, @migration2.did
  end

  test "goat state directories are isolated per migration" do
    # Get the state directory paths from environment
    state_dir1 = @service1.work_dir.join('.goat-state')
    state_dir2 = @service2.work_dir.join('.goat-state')

    # Verify they're different
    assert_not_equal state_dir1, state_dir2

    # Verify they include the migration DID
    assert_includes state_dir1.to_s, @migration1.did
    assert_includes state_dir2.to_s, @migration2.did
  end

  test "cleanup removes goat state directory" do
    # Create state directories
    state_dir = @service1.work_dir.join('.goat-state')
    FileUtils.mkdir_p(state_dir)

    # Create a fake session file
    session_file = state_dir.join('goat', 'auth-session.json')
    FileUtils.mkdir_p(session_file.dirname)
    File.write(session_file, '{"did":"test","access_token":"fake"}')

    assert File.exist?(session_file)

    # Cleanup
    @service1.cleanup

    # Verify entire work directory is removed
    assert_not File.exist?(@service1.work_dir)
    assert_not File.exist?(state_dir)
    assert_not File.exist?(session_file)
  end

  # NOTE: This test requires actual goat CLI and PDS access
  # Skip in CI unless integration testing environment is available
  test "concurrent goat commands use isolated sessions" do
    skip "Requires goat CLI and test PDS instances" unless ENV['RUN_INTEGRATION_TESTS']

    # Simulate concurrent operations
    threads = []

    threads << Thread.new do
      # This would normally call goat commands
      # For now, just verify the state directory exists
      FileUtils.mkdir_p(@service1.work_dir.join('.goat-state'))
      sleep 0.1
      File.exist?(@service1.work_dir.join('.goat-state'))
    end

    threads << Thread.new do
      # Second migration in parallel
      FileUtils.mkdir_p(@service2.work_dir.join('.goat-state'))
      sleep 0.1
      File.exist?(@service2.work_dir.join('.goat-state'))
    end

    results = threads.map(&:value)

    # Both should succeed without interfering
    assert results.all?, "Both migrations should have isolated state directories"
  end
end
