require "net/http"

# Something needs someone. hob has no inbox yet (that is chatelaine's job);
# until then, POST a short message to a channel — an ntfy topic, or anything
# that takes a text body with Title and Tags headers — with HOB_NOTIFY_TOKEN
# as a bearer token when set, and always write it to the log. A person is
# reached at HOB_NOTIFY_URL; a principal (an agent, a worker, a person with
# a phone) at its own `channel`, so that two agents on one household do not
# hear each other's missions. Never raises: a failed ping must not fail the
# thing it was about.
module Notify
  # Tests inject a lambda (url, title, body, headers) -> HTTP status here.
  mattr_accessor :transport

  module_function

  def person(title:, body:, tags: nil, url: ENV["HOB_NOTIFY_URL"], token: ENV["HOB_NOTIFY_TOKEN"])
    post_to(url, title: title, body: body, tags: tags, token: token)
  end

  # The principal's own channel; false (logged only) when it has none.
  def principal(principal, title:, body:, tags: nil, token: ENV["HOB_NOTIFY_TOKEN"])
    post_to(principal&.channel, title: title, body: body, tags: tags, token: token)
  end

  def post_to(url, title:, body:, tags: nil, token: nil)
    Rails.logger.info("notify: #{title} — #{body.to_s.squish.truncate(200)}")
    return false if url.blank?

    headers = { "Title" => title.to_s, "Content-Type" => "text/plain; charset=utf-8" }
    headers["Tags"] = Array(tags).join(",") if tags.present?
    headers["Authorization"] = "Bearer #{token}" if token.present?
    status = (Notify.transport || method(:post)).call(url, title.to_s, body.to_s, headers)
    return true if status.nil? || status.to_s.start_with?("2")

    Rails.logger.warn("notify failed: #{url} answered HTTP #{status}")
    false
  rescue StandardError => e
    Rails.logger.warn("notify failed: #{e.class}: #{e.message}")
    false
  end

  def post(url, _title, body, headers)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    headers.each { |k, v| req[k] = v }
    req.body = body
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |http| http.request(req) }.code
  end
end
