require "test_helper"

# Who the household knows, from the admin pages (PEOPLE.md): the open loops
# and everyone, each person's brief, and the people.* requests only a person
# may approve, shown as what they would do.
class AdminPeopleControllerTest < ActionDispatch::IntegrationTest
  setup do
    admin_signing_in!
    native_capabilities!
    @muse, @agent_token = agent("muse")
    policy!(@muse, "people.*", "allow")
    Notify.transport = ->(*) { }
    by = People::Writer.new(principal: @muse, surface: "muse")
    Current.set(clearance: "household") do
      @eugene = People.create({ "display_name" => "Eugene <b>Fox</b>", "handles" => [ "+15550001111" ], "circles" => [ "biker gang" ] }, by: by)
      @other = People.create({ "display_name" => "Eugene (new)", "handles" => [ "+15559990000" ] }, by: by)
      People.record({ "person" => @eugene.id, "kind" => "reached_out", "direction" => "inbound", "channel" => "text",
                      "at" => "2026-10-07T18:00:00Z", "summary" => "text from Eugene" }, by: by)
      People.note({ "person" => @eugene.id, "body" => "Festival crew" }, by: by)
    end
  end

  teardown do
    admin_signed_out!
    Notify.transport = nil
  end

  test "the index shows open loops and everyone; a person's page shows the brief" do
    admin_sign_in
    get "/admin/people"
    assert_response :ok
    assert_select "tr[id^=loop-]", /unanswered inbound/
    assert_select "td", /Eugene \(new\)/

    get "/admin/people/#{@eugene.id}"
    assert_response :ok
    assert_select "dd", /\+15550001111/
    assert_select "p", /Festival crew/
    assert_includes response.body, "Eugene &lt;b&gt;Fox&lt;/b&gt;", "a sender's name is text"

    get "/admin/people?q=new"
    assert_select "td a[href='/admin/people/#{@eugene.id}']", count: 1 # the loop's row, not everyone's
  end

  test "a merge request shows both records, escaped" do
    post "/v1/sentinel/requests", params: { capability: "people.merge", reason: "same person",
                                            arguments: { into: @eugene.id, from: @other.id, reason: "new number" } },
                                  headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
    assert_equal "pending", body["status"], body.to_s
    id = body["id"]
    admin_sign_in
    get "/admin/sentinel"
    assert_response :ok
    assert_select "#request-#{id}", /Fold in/
    assert_includes response.body, "Eugene &lt;b&gt;Fox&lt;/b&gt;"
    refute_includes response.body, "Eugene <b>Fox</b>"
  end
end
