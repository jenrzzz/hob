require "test_helper"

# POST /v1/plugins/announce (PLUGINS.md, Phase 1b): an installation that
# signs its manifest asks hob to re-read it, signed with its own key.
class PluginAnnouncementsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @plugin = Plugin.install!(namespace: "mise", plugin_type: "mise", base_url: "https://mise.test")
    @plugin.update!(key: "k" * 64, key_confirmed_at: Time.current, signed_since: Time.current)
    Rails.cache.clear
  end

  def announce(namespace: "mise", key: @plugin.key, body: "{}", timestamp: Time.now.to_i, signature: nil)
    signature ||= PluginSignature.sign_announcement(key: key, namespace: namespace, body: body, timestamp: timestamp)
    post "/v1/plugins/announce", params: body,
         headers: { "Content-Type" => "application/json", "X-Hob-Installation" => namespace, "X-Hob-Signature" => signature }
  end

  test "a signed announcement queues one refresh, and another within the minute does not queue a second" do
    assert_enqueued_with(job: PluginRefreshJob, args: [ "mise" ]) { announce }
    assert_response :accepted
    assert @plugin.reload.announced_at

    assert_no_enqueued_jobs(only: PluginRefreshJob) { announce }
    assert_response :accepted

    travel V1::PluginAnnouncementsController::DEBOUNCE + 1.second do
      assert_enqueued_with(job: PluginRefreshJob) { announce }
    end
  end

  test "an announcement that does not verify is refused and never touches the installation it names" do
    [
      -> { announce(key: "wrong") },
      -> { announce(timestamp: 10.minutes.ago.to_i) },
      -> { announce(namespace: "parboil") },
      -> { announce(signature: "t=#{Time.now.to_i},v1=") },
      -> { announce(signature: PluginSignature.sign_manifest(key: @plugin.key, namespace: "mise", revision: 1, nonce: "n", kid: "", body: "{}")) }
    ].each do |attempt|
      assert_no_enqueued_jobs { attempt.call }
      assert_response :unauthorized
    end
    assert_nil @plugin.reload.announced_at
    assert @plugin.signed?
  end

  test "the body is signed: changing it after signing fails" do
    signature = PluginSignature.sign_announcement(key: @plugin.key, namespace: "mise", body: "{}")
    announce(body: '{"x":1}', signature: signature)
    assert_response :unauthorized
  end

  test "an installation that has never signed its manifest, or is quarantined, may not ask" do
    @plugin.update!(signed_since: nil)
    assert_no_enqueued_jobs { announce }
    assert_response :forbidden

    @plugin.update!(signed_since: Time.current)
    @plugin.quarantine!(reason: "looking into it")
    assert_no_enqueued_jobs { announce }
    assert_response :forbidden
  end

  test "the plugin key reaches nothing else" do
    get "/v1/sentinel/capabilities", headers: { "Authorization" => "Bearer #{@plugin.key}" }
    assert_response :unauthorized
  end

  test "a refused automatic refresh tells a person" do
    told = []
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/house"
    Notify.transport = ->(_url, title, body, _headers) { told << [ title, body ]; "200" }
    @plugin.update!(signed_since: nil)

    PluginRefreshJob.perform_now("mise")

    assert_match(/mise asked to be refreshed, and was refused/, told.first[0])
    assert_match(/never signed/, told.first[1])
  ensure
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end
end
