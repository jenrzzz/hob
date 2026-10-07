require "test_helper"
require "socket"

# Web (HTTP.md): one request to the public internet, and never into the
# house. The transport and resolver are replaced, so nothing here reaches
# DNS or the network but the last test, which talks to a socket of its own.
class WebTest < ActiveSupport::TestCase
  PUBLIC = "93.184.215.14".freeze

  setup do
    @sent = []
    @dns = Hash.new { |_, _host| [ PUBLIC ] }
    @pages = {}
    Web.resolver = ->(host) { @dns[host] }
    Web.transport = lambda do |verb, uri, address, body, headers|
      @sent << { verb: verb, url: uri.to_s, address: address, body: body, headers: headers }
      @pages.fetch(uri.to_s) { [ 200, "ok", { "Content-Type" => "text/plain" } ] }
    end
  end

  teardown do
    Web.resolver = nil
    Web.transport = nil
    ENV.delete("HOB_HTTP_DENY")
  end

  test "a GET of a public page: the text of it, the connection pinned to the address that was checked" do
    @pages["https://news.example/unsub?u=1"] = [ 200, "<html><head><title>x</title><script>evil()</script></head>" \
                                                     "<body><h1>Unsubscribed</h1><p>You&rsquo;re off the list.</p></body></html>",
                                                 { "Content-Type" => "text/html; charset=utf-8", "Set-Cookie" => "s=1" } ]
    result = Web.get("url" => "https://news.example/unsub?u=1#top")

    assert_equal [ 200, true, "text/html" ], result.values_at("status", "ok", "content_type")
    assert_equal "Unsubscribed\nYou’re off the list.", result["body"]
    assert_equal false, result["body_truncated"]
    assert_equal({ "content-type" => "text/html; charset=utf-8" }, result["headers"], "cookies stay with hob")
    assert_equal [ "GET", "https://news.example/unsub?u=1", PUBLIC, nil ], @sent.first.values_at(:verb, :url, :address, :body)
    assert_match(/\Ahob/, @sent.first[:headers]["User-Agent"])
    assert_includes Web.get("url" => "https://news.example/unsub?u=1", "raw" => true)["body"], "<h1>Unsubscribed</h1>"
  end

  test "nothing inside the house: loopback, private, the tailnet, link-local, and their IPv6 forms" do
    {
      "127.0.0.1" => "loopback", "10.1.2.3" => "lan", "192.168.1.10" => "router", "172.20.0.5" => "docker",
      "100.90.105.100" => "tailnet", "169.254.169.254" => "metadata", "0.0.0.0" => "any", "::1" => "v6 loopback",
      "::ffff:127.0.0.1" => "mapped", "fd7a:115c:a1e0::1" => "tailnet v6", "fe80::1" => "v6 link-local",
      "64:ff9b::a00:1" => "nat64", "2002:7f00:1::1" => "6to4"
    }.each do |address, what|
      @dns["inside.example"] = [ address ]
      error = assert_raises(Web::Blocked, what) { Web.get("url" => "http://inside.example/") }
      assert_match(/resolves to #{Regexp.escape(address)}/, error.message)
    end
    @dns["split.example"] = [ PUBLIC, "10.0.0.8" ]
    assert_raises(Web::Blocked, "one inside address is enough") { Web.get("url" => "https://split.example/") }
    assert_raises(Web::Blocked) { Web.get("url" => "http://127.0.0.1/") }
    assert_raises(Web::Blocked) { Web.get("url" => "http://[::1]/") }
    assert_empty @sent, "nothing went"
  end

  test "only http and https, on their own ports, with no credentials in the URL" do
    assert_match(/http or https/, assert_raises(Web::Invalid) { Web.get("url" => "file:///etc/passwd") }.message)
    assert_match(/http or https/, assert_raises(Web::Invalid) { Web.get("url" => "gopher://news.example/") }.message)
    assert_match(/port 5432/, assert_raises(Web::Blocked) { Web.get("url" => "http://news.example:5432/") }.message)
    assert_match(/user name/, assert_raises(Web::Invalid) { Web.get("url" => "https://me:pw@news.example/") }.message)
    assert_raises(Web::Invalid) { Web.get("url" => "") }
    assert_raises(Web::Invalid) { Web.get("url" => "https://news.example/", "method" => "DELETE") }
    assert_empty @sent
  end

  test "HOB_HTTP_DENY: the household's own names and addresses" do
    ENV["HOB_HTTP_DENY"] = "amber.place, 203.0.114.0/24"
    assert_match(/deny list/, assert_raises(Web::Blocked) { Web.get("url" => "https://hob.amber.place/v1/usage") }.message)
    assert_raises(Web::Blocked) { Web.get("url" => "https://amber.place/") }
    @dns["box.example"] = [ "203.0.114.9" ]
    assert_match(/deny list/, assert_raises(Web::Blocked) { Web.get("url" => "https://box.example/") }.message)
    assert_equal 200, Web.get("url" => "https://notamber.place/")["status"], "a suffix, not a substring"
  end

  test "a GET follows redirects and checks every hop; a POST does not follow" do
    @pages["https://news.example/a"] = [ 302, "", { "Location" => "/b" } ]
    @pages["https://news.example/b"] = [ 301, "", { "Location" => "https://cdn.example/done" } ]
    result = Web.get("url" => "https://news.example/a")
    assert_equal [ "https://cdn.example/done", [ "https://news.example/a", "https://news.example/b" ] ],
                 result.values_at("final_url", "redirects")

    @pages["https://news.example/sneaky"] = [ 302, "", { "Location" => "http://metadata.example/latest" } ]
    @dns["metadata.example"] = [ "169.254.169.254" ]
    assert_raises(Web::Blocked) { Web.get("url" => "https://news.example/sneaky") }
    refute(@sent.any? { |s| s[:url].include?("metadata") }, "the hop inside was never made")

    @pages["https://news.example/loop"] = [ 302, "", { "Location" => "/loop" } ]
    assert_match(/redirects/, assert_raises(Web::Unavailable) { Web.get("url" => "https://news.example/loop") }.message)

    @pages["https://news.example/form"] = [ 303, "", { "Location" => "/thanks" } ]
    posted = Web.post("url" => "https://news.example/form")
    assert_equal [ 303, "/thanks" ], [ posted["status"], posted.dig("headers", "location") ]
    refute(@sent.any? { |s| s[:url].end_with?("/thanks") })
  end

  test "a POST: one-click unsubscribe as a form, or JSON, or a body; one of them" do
    Web.post("url" => "https://news.example/unsub", "form" => { "List-Unsubscribe" => "One-Click" })
    assert_equal [ "POST", "List-Unsubscribe=One-Click", "application/x-www-form-urlencoded" ],
                 [ @sent.last[:verb], @sent.last[:body], @sent.last[:headers]["Content-Type"] ]
    Web.post("url" => "https://api.example/x", "json" => { "a" => [ 1 ] })
    assert_equal [ '{"a":[1]}', "application/json" ], [ @sent.last[:body], @sent.last[:headers]["Content-Type"] ]
    Web.post("url" => "https://api.example/x", "body" => "<x/>", "content_type" => "application/xml")
    assert_equal "application/xml", @sent.last[:headers]["Content-Type"]

    assert_raises(Web::Invalid) { Web.post("url" => "https://api.example/x", "form" => { "a" => "1" }, "json" => {}) }
    assert_raises(Web::Invalid) { Web.post("url" => "https://api.example/x", "form" => { "a" => { "b" => 1 } }) }
    assert_raises(Web::Invalid) { Web.post("url" => "https://api.example/x", "json" => {}, "content_type" => "text/csv") }
    assert_raises(Web::Invalid) { Web.post("url" => "https://api.example/x", "body" => "x" * (Web::MAX_REQUEST_BODY + 1)) }
  end

  test "request headers: the caller adds, hob keeps the connection" do
    Web.get("url" => "https://news.example/", "headers" => { "Accept-Language" => "en" })
    assert_equal "en", @sent.last[:headers]["Accept-Language"]
    assert_raises(Web::Invalid) { Web.get("url" => "https://news.example/", "headers" => { "Host" => "localhost" }) }
    assert_raises(Web::Invalid) { Web.get("url" => "https://news.example/", "headers" => { "X-A" => "1\r\nHost: x" }) }
    assert_raises(Web::Invalid) { Web.get("url" => "https://news.example/", "headers" => { "Bad Name" => "1" }) }
    assert_raises(Web::Invalid) { Web.get("url" => "https://news.example/", "headers" => "Accept: */*") }
  end

  test "bodies: a status is an answer, binary is not shown, long text is cut, charsets are honoured" do
    @pages["https://news.example/gone"] = [ 404, "no such list", { "Content-Type" => "text/plain" } ]
    assert_equal [ 404, false, "no such list" ], Web.get("url" => "https://news.example/gone").values_at("status", "ok", "body")

    @pages["https://news.example/logo.png"] = [ 200, "\x89PNG\r\n".b + ("\0" * 100), { "Content-Type" => "image/png" } ]
    png = Web.get("url" => "https://news.example/logo.png")
    assert_nil png["body"]
    assert_match(/image\/png is not text; 106 bytes/, png["body_omitted"])

    @pages["https://news.example/long"] = [ 200, "x" * 50, { "Content-Type" => "text/plain" } ]
    long = Web.get("url" => "https://news.example/long", "max_chars" => 10)
    assert_equal [ "x" * 10, true ], long.values_at("body", "body_truncated")

    @pages["https://news.example/latin"] = [ 200, "caf\xE9".b, { "Content-Type" => "text/plain; charset=iso-8859-1" } ]
    assert_equal "café", Web.get("url" => "https://news.example/latin")["body"]
  end

  test "the wire: pinned to the checked address, the name kept for Host, the body capped" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    seen = Queue.new
    thread = Thread.new do
      client = server.accept
      request = +""
      request << client.readpartial(4096) until request.include?("\r\n\r\n")
      seen << request
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{Web::MAX_BYTES + 10}\r\n\r\n")
      client.write("y" * (Web::MAX_BYTES + 10))
    rescue IOError, SystemCallError
      nil
    ensure
      client&.close
    end

    status, response, headers = Web.http("GET", URI("http://news.example:#{port}/p?q=1"), "127.0.0.1", nil,
                                         { "User-Agent" => "t" }, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
    request = seen.pop
    assert_match(%r{\AGET /p\?q=1 HTTP/1.1\r\n}, request)
    assert_match(/^Host: news\.example:#{port}\r$/, request)
    assert_equal [ "200", true, Web::MAX_BYTES ], [ status, response[:truncated], response[:body].bytesize ]
    assert_equal [ "text/plain" ], headers["content-type"]
  ensure
    thread&.join(2)
    server&.close
  end
end
