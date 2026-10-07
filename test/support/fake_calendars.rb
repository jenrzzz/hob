# Calendar servers as far as hob uses them, answering from canned data: what
# Calendars::Backends::Base.transport is pointed at in tests. Feeds are
# served at their URL; a CalDAV account (Fastmail's layout) answers PROPFIND
# on its calendar home and a calendar-query REPORT on each calendar. Every
# call is kept; a response pushed with `respond` is served first.
class FakeCalendars
  Call = Struct.new(:verb, :url, :body, :headers)

  HOME = "https://caldav.fastmail.com/dav/calendars/user/jenner@fastmail.test/".freeze

  attr_reader :calls, :feeds

  def initialize
    @calls = []
    @queued = []
    @feeds = {}
    @calendars = {}
  end

  def to_proc
    method(:call).to_proc
  end

  def respond(status, body = "", headers = {})
    @queued << [ status, body, headers ]
  end

  def feed(url, text)
    @feeds[url] = text
  end

  # A calendar on the fake CalDAV account: its id, name, and the iCalendar
  # resources in it.
  def calendar(id, name, resources, color: "#3a87adff", read_only: false)
    @calendars[id] = { name: name, resources: resources, color: color, read_only: read_only }
  end

  def call(verb, url, body, headers)
    @calls << Call.new(verb, url, body, headers)
    return @queued.shift if @queued.any?
    return feed_answer(url) if verb == "GET"
    return [ 207, propfind ] if verb == "PROPFIND" && url == HOME

    id = url.delete_prefix(HOME).delete_suffix("/")
    return [ 207, report(@calendars.fetch(id)) ] if verb == "REPORT" && @calendars.key?(id)

    [ 404, "" ]
  end

  private

  def feed_answer(url)
    @feeds.key?(url) ? [ 200, @feeds[url], { "content-type" => "text/calendar" } ] : [ 404, "not here" ]
  end

  def propfind
    responses = [ response(HOME, "<d:resourcetype><d:collection/></d:resourcetype>") ]
    responses << response("#{HOME}Inbox/", "<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>")
    @calendars.each do |id, calendar|
      privileges = calendar[:read_only] ? "<d:privilege><d:read/></d:privilege>" : "<d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege>"
      responses << response("#{URI(HOME).path}#{id}/", <<~XML)
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
        <d:displayname>#{calendar[:name]}</d:displayname>
        <a:calendar-color>#{calendar[:color]}</a:calendar-color>
        <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set>
        <d:current-user-privilege-set>#{privileges}</d:current-user-privilege-set>
      XML
    end
    multistatus(responses.join)
  end

  def report(calendar)
    multistatus(calendar[:resources].each_with_index.map do |text, index|
      "<d:response><d:href>#{index}.ics</d:href><d:propstat><d:prop><d:getetag>\"#{index}\"</d:getetag>" \
        "<c:calendar-data>#{ERB::Util.html_escape(text)}</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    end.join)
  end

  def response(href, props)
    "<d:response><d:href>#{href}</d:href><d:propstat><d:prop>#{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>" \
      "<d:propstat><d:prop><c:calendar-timezone/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>"
  end

  def multistatus(inner)
    %(<?xml version="1.0" encoding="utf-8"?>\n<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" ) +
      %(xmlns:a="http://apple.com/ns/ical/">#{inner}</d:multistatus>)
  end
end
