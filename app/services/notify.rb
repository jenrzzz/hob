require "net/http"

# Something needs a person. hob has no inbox yet (that is chatelaine's job);
# until then, POST a short message to HOB_NOTIFY_URL — an ntfy topic, or
# anything that takes a text body with Title and Tags headers — and always
# write it to the log. Never raises: a failed ping must not fail the thing
# it was about.
module Notify
  # Tests inject a lambda (url, title, body, headers) here.
  mattr_accessor :transport

  module_function

  def person(title:, body:, tags: nil, url: ENV["HOB_NOTIFY_URL"])
    Rails.logger.info("notify: #{title} — #{body.to_s.squish.truncate(200)}")
    return false if url.blank?

    headers = { "Title" => title.to_s, "Content-Type" => "text/plain; charset=utf-8" }
    headers["Tags"] = Array(tags).join(",") if tags.present?
    (Notify.transport || method(:post)).call(url, title.to_s, body.to_s, headers)
    true
  rescue StandardError => e
    Rails.logger.warn("notify failed: #{e.class}: #{e.message}")
    false
  end

  def post(url, _title, body, headers)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    headers.each { |k, v| req[k] = v }
    req.body = body
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |http| http.request(req) }
  end
end
