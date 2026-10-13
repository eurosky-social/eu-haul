require "test_helper"

# Bluesky mails PLC confirmation codes from noreply@bsky.app whatever shard
# hosts the account; everyone else is named by their old PDS's host.
class PlcMailSenderTest < ActiveSupport::TestCase
  test "a Bluesky shard is shown as Bluesky with the address the mail comes from" do
    assert_equal "Bluesky (noreply@bsky.app)", PlcMailSender.display("https://shimeji.us-east.host.bsky.network")
    assert_equal "Bluesky (noreply@bsky.app)", PlcMailSender.display("https://bsky.social")
    assert_equal "Bluesky (noreply@bsky.app)", PlcMailSender.display("https://Porcini.US-East.host.bsky.network/")
  end

  test "any other PDS is shown by its bare host" do
    assert_equal "pds.example.eu", PlcMailSender.display("https://pds.example.eu")
    assert_equal "pds.example.eu", PlcMailSender.display("https://pds.example.eu:443/xrpc")
    assert_equal "scios.network", PlcMailSender.display("scios.network")
  end

  test "a look-alike host is not mistaken for Bluesky" do
    assert_equal "notbsky.social", PlcMailSender.display("https://notbsky.social")
    assert_equal "bsky.network.example.org", PlcMailSender.display("https://bsky.network.example.org")
  end

  test "blank input comes back unchanged" do
    assert_equal "", PlcMailSender.display(nil)
    assert_equal "", PlcMailSender.display("")
  end
end
