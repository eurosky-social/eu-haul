# frozen_string_literal: true

# The sender a PLC confirmation code arrives from, as the user will see it in
# their inbox.
#
# The migration records the old PDS by hostname, and for accounts hosted by
# Bluesky that is a shard such as shimeji.us-east.host.bsky.network. The code
# itself is mailed by Bluesky's entryway from noreply@bsky.app, so people who
# searched their inbox for the shard name found nothing and concluded the mail
# never came. Name Bluesky for those hosts; everyone else gets the bare host of
# their old PDS, which is what their mail client shows too.
module PlcMailSender
  BLUESKY_HOSTS = /\A(?:[a-z0-9-]+\.)*bsky\.(?:network|social)\z/i
  BLUESKY_LABEL = "Bluesky (noreply@bsky.app)"

  def self.display(pds_host)
    host = pds_host.to_s.strip.sub(%r{\Ahttps?://}i, "").sub(%r{[/:?#].*\z}, "")
    return pds_host.to_s if host.empty?

    host.match?(BLUESKY_HOSTS) ? BLUESKY_LABEL : host.downcase
  end
end
