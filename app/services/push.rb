require "stringio"

# The companion app (clients/ios) over APNs: when the sentinel needs a
# person, every phone a person has registered (Device) gets a notification
# that opens the petition or request in the app. Token-based auth, the same
# shape kat uses, so one .p8 key serves every app on the team:
#
#   APNS_KEY        the .p8 contents (PEM; "\n" escapes are unescaped so the
#                   key survives a single-line secret store), or
#   APNS_KEY_PATH   a path to the .p8 file
#   APNS_KEY_ID     the 10-character key id from the developer portal
#   APNS_TEAM_ID    the 10-character team id
#   APNS_BUNDLE_ID  the app's bundle id (default: place.amber.hob)
#
# Sandbox vs production is per device: the app reports which aps-environment
# it was signed with when it registers, and each send goes to that host.
# Reached through Notify.person (`about:` says what to open); Push.people
# never raises and a dead token is deleted when Apple says so.
module Push
  class Error < StandardError; end
  class Unregistered < Error; end   # the token will never work again
  class NotConfigured < Error; end

  DEFAULT_BUNDLE_ID = "place.amber.hob"
  EXPIRATION = 1.hour
  # Reasons Apple gives for a token to drop rather than retry.
  DEAD_REASONS = %w[BadDeviceToken Unregistered DeviceTokenNotForTopic ExpiredToken].freeze

  # Tests inject a lambda (device, notification hash) -> [status, reason] here.
  mattr_accessor :transport

  module_function

  def configured?
    key.present? && key_id.present? && team_id.present?
  end

  def available?
    configured? || transport.present?
  end

  def bundle_id = ENV.fetch("APNS_BUNDLE_ID", DEFAULT_BUNDLE_ID)
  def key_id = ENV["APNS_KEY_ID"]
  def team_id = ENV["APNS_TEAM_ID"]

  # The signing key as PEM text, whichever way it was provided.
  def key
    if (path = ENV["APNS_KEY_PATH"]).present?
      File.read(path) if File.exist?(path)
    elsif (pem = ENV["APNS_KEY"]).present?
      pem.gsub("\\n", "\n")
    end
  end

  # Every phone every person has registered. Returns how many accepted.
  def people(title:, body:, about: nil)
    return 0 unless available?

    Device.of_people.includes(:principal).to_a.count { |device| deliver?(device, title: title, body: body, about: about) }
  end

  # One device; true when Apple accepted, false otherwise, never raises.
  def deliver?(device, title:, body:, about: nil)
    deliver!(device, title: title, body: body, about: about)
    true
  rescue Unregistered => e
    Rails.logger.warn("push: #{device.label} token is dead (#{e.message}); forgetting it")
    device.destroy
    false
  rescue StandardError => e
    Rails.logger.warn("push failed for #{device.label}: #{e.class}: #{e.message}")
    false
  end

  # One device; raises Unregistered for a dead token, Error otherwise.
  def deliver!(device, title:, body:, about: nil)
    raise NotConfigured, "APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID are not set on hob" unless available?

    note = notification(title: title, body: body, about: about)
    status, reason = (transport || method(:apns)).call(device, note)
    raise Error, "no response from APNs" if status.nil?

    if status.to_s.start_with?("2")
      device.update_column(:last_pushed_at, Time.current)
      return true
    end
    raise Unregistered, "#{status} #{reason}" if status.to_s == "410" || DEAD_REASONS.include?(reason.to_s)

    raise Error, "#{status} #{reason}"
  end

  # What the phone receives. `hob` is what the app reads: kind and id say
  # what to open; category and thread group the banners per item, and the
  # collapse id lets a later state of the same item replace an earlier one.
  def notification(title:, body:, about: nil)
    link = link_for(about)
    {
      title: title.to_s, body: body.to_s, category: link&.dig(:kind), thread: link && "#{link[:kind]}/#{link[:id]}",
      hob: link
    }.compact
  end

  # The companion app's URL for an item: the ntfy message's click action.
  def deep_link(about)
    link = link_for(about)
    link && "hob://#{link[:kind]}/#{link[:id]}"
  end

  def link_for(about)
    case about
    when Petition then { kind: "petition", id: about.id, status: about.status }
    when SentinelRequest then { kind: "request", id: about.id, status: about.status }
    when Hash then about.symbolize_keys
    end
  end

  # The real transport: a connection per send. Volume is a few a day, and a
  # fresh HTTP/2 session is simpler than a long-lived one shared by threads.
  def apns(device, note)
    notification = Apnotic::Notification.new(device.token).tap do |n|
      n.topic = bundle_id
      n.push_type = "alert"
      n.alert = { title: note[:title], body: note[:body] }
      n.sound = "default"
      n.category = note[:category] if note[:category]
      n.thread_id = note[:thread] if note[:thread]
      n.apns_collapse_id = note[:thread] if note[:thread]
      n.expiration = EXPIRATION.from_now.to_i.to_s
      n.custom_payload = { hob: note[:hob] } if note[:hob]
    end
    options = { auth_method: :token, cert_path: StringIO.new(key), key_id: key_id, team_id: team_id, connect_timeout: 10 }
    connection = device.sandbox? ? Apnotic::Connection.development(options) : Apnotic::Connection.new(options)
    begin
      response = connection.push(notification, timeout: 10)
    ensure
      connection.close
    end
    return [ nil, nil ] if response.nil?

    [ response.status, response.body.is_a?(Hash) ? response.body["reason"] : response.body ]
  end
end
