require "test_helper"

class NotifyTest < ActiveSupport::TestCase
  teardown { Notify.transport = nil }

  test "posts a titled text body to HOB_NOTIFY_URL and never raises" do
    sent = []
    Notify.transport = ->(url, title, body, headers) { sent << [ url, title, body, headers ]; "200" }
    assert_not Notify.person(title: "t", body: "b", url: nil), "no URL: logged only"
    assert Notify.person(title: "hob: hello", body: "there", tags: "bell", url: "https://ntfy.test/hob")
    url, title, body, headers = sent.last
    assert_equal "https://ntfy.test/hob", url
    assert_equal "hob: hello", title
    assert_equal "there", body
    assert_equal "hob: hello", headers["Title"]
    assert_equal "bell", headers["Tags"]
    assert_nil headers["Authorization"]
    assert Notify.person(title: "t", body: "b", url: "https://ntfy.test/hob", token: "tk_x")
    assert_equal "Bearer tk_x", sent.last[3]["Authorization"]

    Notify.transport = ->(*) { raise IOError, "boom" }
    assert_not Notify.person(title: "t", body: "b", url: "https://ntfy.test/hob")
    Notify.transport = ->(*) { "403" }
    assert_not Notify.person(title: "t", body: "b", url: "https://ntfy.test/hob"), "a rejected token is a failure"
    Notify.transport = ->(*) { "200" }
    assert Notify.person(title: "t", body: "b", url: "https://ntfy.test/hob")
  end
end
