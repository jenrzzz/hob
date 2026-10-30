require "test_helper"

# The ward over HTTP: the worker posts, a person reads and decides, agents
# and surfaces are turned away.
class WardControllerTest < ActionDispatch::IntegrationTest
  REPORT = "WARN  mise: review — public recipe app\nFAIL  cadance 203.0.113.9:8888: unexpected public TCP port\nOK    done\nOK=1 WARN=1 FAIL=1 ERROR=0\n"

  setup do
    WardCheck.create!(slug: "exposure")
    @worker = Principal.create!(name: "ward", kind: "worker", max_clearance: "personal")
    @worker_token = ApiKey.issue!(principal: @worker, surface: "ward", default_clearance: "personal")
    Notify.transport = ->(*) { "200" }
  end

  teardown { Notify.transport = nil }

  def worker_auth
    { "Authorization" => "Bearer #{@worker_token}" }
  end

  test "the worker posts a report and gets the diff back" do
    @fake.reply({ severity: "attention", headline: "h", summary: "s", next_steps: [] }.to_json)
    @fake.reply({ severity: "info", headline: "h2", summary: "s", next_steps: [] }.to_json)
    post "/v1/ward/runs", params: { check: "exposure", exit_code: 1, output: REPORT, started_at: "2026-09-20T06:00:00Z", finished_at: "2026-09-20T06:20:00Z" },
         headers: worker_auth, as: :json
    assert_response :created
    assert_equal "exposure", body["check"]
    assert_equal "ward", body["posted_by"]
    assert body["complete"]
    assert_equal({ "ok" => 1, "warn" => 1, "fail" => 1, "error" => 0 }, body["counts"])
    assert_equal 2, body["changes"]["new"].size
    assert_equal "fail", body["changes"]["new"].first["level"], "most severe first"
    assert_equal "2026-09-20T06:00:00Z", body["started_at"]
    assert_equal "exposure: 2 new (1 FAIL)", body["summary"]
    assert_equal @worker, WardRun.last.principal

    post "/v1/ward/runs", params: { check: "exposure", exit_code: 1, lines: [ "WARN mise: review — public recipe app" ], mission: "01M" },
         headers: worker_auth, as: :json
    assert_response :created
    assert_equal 1, body["changes"]["resolved"].size
    assert_equal "01M", body["mission"]

    post "/v1/ward/runs", params: { check: "nope", exit_code: 1, output: REPORT }, headers: worker_auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/no ward check named "nope"/, body["error"])
    post "/v1/ward/runs", params: { check: "exposure", exit_code: 1 }, headers: worker_auth, as: :json
    assert_response :unprocessable_entity
    post "/v1/ward/runs", params: { check: "exposure", exit_code: 1, output: REPORT, started_at: "yesterday-ish" }, headers: worker_auth, as: :json
    assert_response :unprocessable_entity
  end

  test "agents and surfaces cannot post or read; a person can post too" do
    _muse, agent_token = agent("muse", clearance: "personal")
    post "/v1/ward/runs", params: { check: "exposure", exit_code: 0, output: "OK fine" }, headers: { "Authorization" => "Bearer #{agent_token}" }, as: :json
    assert_response :forbidden
    get "/v1/ward/status", headers: { "Authorization" => "Bearer #{agent_token}" }
    assert_response :forbidden

    surface = Principal.create!(name: "mise", kind: "surface", max_clearance: "household")
    surface_token = ApiKey.issue!(principal: surface, surface: "mise", default_clearance: "household")
    post "/v1/ward/runs", params: { check: "exposure", exit_code: 0, output: "OK fine" }, headers: { "Authorization" => "Bearer #{surface_token}" }, as: :json
    assert_response :forbidden
    get "/v1/ward/findings", headers: { "Authorization" => "Bearer #{surface_token}" }
    assert_response :forbidden

    post "/v1/ward/runs", params: { check: "exposure", exit_code: 0, output: "OK fine" }, headers: auth, as: :json
    assert_response :created
    get "/v1/ward/status", headers: worker_auth
    assert_response :forbidden, "the worker posts; it does not read"
  end

  test "a person reads status and findings, acknowledges with an expiry, and leaves notes" do
    @fake.reply({ severity: "attention", headline: "8888 is public on cadance", summary: "s", next_steps: [ "bind it" ] }.to_json)
    post "/v1/ward/runs", params: { check: "exposure", exit_code: 1, output: REPORT }, headers: worker_auth, as: :json
    assert_equal "8888 is public on cadance", body["triage"]["headline"]
    port = WardFinding.find_by!(level: "fail")

    get "/v1/ward/status", headers: auth
    assert_response :ok
    check = body["checks"].first
    assert_equal "exposure", check["slug"]
    assert_not check["stale"]
    assert_equal 2, check["open"]
    assert_equal 2, body["open"].size
    assert_empty body["acknowledged"]
    assert_equal "8888 is public on cadance", body["triage"]["headline"]
    assert_equal [ "bind it" ], body["triage"]["next_steps"]

    post "/v1/ward/findings/#{port.id}/ack", params: { note: "proxy; auth required", until: 30.days.from_now.iso8601 }, headers: auth, as: :json
    assert_response :ok
    assert_equal "acknowledged", body["state"]
    assert_equal "tester", body["acknowledged_by"]
    assert_equal "proxy; auth required", body["ack_note"]

    get "/v1/ward/findings", headers: auth
    assert_equal [ "warn" ], body.map { |f| f["level"] }, "open by default"
    get "/v1/ward/findings?state=acknowledged", headers: auth
    assert_equal [ port.id ], body.map { |f| f["id"] }
    get "/v1/ward/findings?state=all&check=exposure", headers: auth
    assert_equal 2, body.size
    get "/v1/ward/findings?state=bogus", headers: auth
    assert_response :unprocessable_entity

    post "/v1/ward/findings/#{port.id}/unack", headers: auth, as: :json
    assert_equal "open", body["state"]
    post "/v1/ward/findings/#{port.id}/ack", params: { until: 1.day.ago.iso8601 }, headers: auth, as: :json
    assert_response :unprocessable_entity

    post "/v1/ward/notes", params: { subject: "cadance", body: "8888 is an HTTP proxy; auth required on it." }, headers: auth, as: :json
    assert_response :created
    assert_equal "tester", body["author"]
    get "/v1/ward/notes?subject=cadance", headers: auth
    assert_equal 1, body.size
    get "/v1/ward/notes?subject=other", headers: auth
    assert_empty body

    get "/v1/ward/runs?check=exposure", headers: auth
    assert_equal 1, body.size
    assert_equal "exposure: 2 new (1 FAIL)", body.first["summary"]
  end

  test "status runs the sweep, so a quiet check shows as stale" do
    travel 9.days
    @fake.reply({ severity: "attention", headline: "quiet", summary: "s", next_steps: [] }.to_json)
    get "/v1/ward/status", headers: auth
    assert body["checks"].first["stale"]
    assert_equal [ "error" ], body["open"].map { |f| f["level"] }
    assert_equal "attention", body["triage"]["severity"]
  end

  test "threats over HTTP: a person reports and decides; the worker posts a probe; agents are turned away" do
    coolify = WardAsset.create!(ref: "coolify", name: "coolify", kind: "control_plane", source: "coolify", exposure: "public",
                                components: { "php" => nil })
    post "/v1/ward/threats", params: { kind: "cve", title: "PHP2Shell", cve_ids: [ "CVE-2026-109618" ], component: "php",
                                       fixed_versions: { "8.3" => "8.3.36" }, exploited: true }, headers: auth, as: :json
    assert_response :created
    id = body["id"]
    assert_equal [ "exposed", "unverified", "critical", false ], body.values_at("status", "confidence", "assessed_severity", "merged")

    post "/v1/ward/observations", params: { asset: "coolify", component: "php", version: "8.3.36" }, headers: worker_auth, as: :json
    assert_response :created
    assert_equal [ "probe", "ward" ], body.values_at("source", "by")
    assert_equal "8.3.36", coolify.believed("php").first

    post "/v1/ward/observations", params: { asset: "coolify", component: "linux_kernel", version: "6.8.0-139", started_at: "2026-09-14T18:08:18Z",
                                            data: { scheme: "Ubuntu", release: "6.8.0-139-generic", distro: "ubuntu" } }, headers: worker_auth, as: :json
    assert_response :created
    assert_equal({ "scheme" => "ubuntu", "release" => "6.8.0-139-generic", "distro" => "ubuntu" }, body["data"])
    assert_equal "2026-09-14T18:08:18Z", body["started_at"]
    post "/v1/ward/observations", params: { asset: "coolify", component: "linux_kernel", version: "1", data: { nested: { a: 1 } } },
                                  headers: worker_auth, as: :json
    assert_response :unprocessable_entity

    post "/v1/ward/observations", params: { asset: "coolify", image: "ghcr.io/coollabsio/coolify:latest", version: "4.5.3",
                                            digest: "sha256:#{'a' * 64}", data: { container: "coolify", resolved_by: "image label" } },
                                  headers: worker_auth, as: :json
    assert_response :created
    assert_equal [ "coolify", "4.5.3", "ghcr.io/coollabsio/coolify:latest" ], body.values_at("component", "version").push(body.dig("data", "image")),
                 "an image is the product it runs, read the way the inventory reads it"
    post "/v1/ward/observations", params: { asset: "coolify", version: "1" }, headers: worker_auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/component or image/, body["error"])

    post "/v1/ward/observations", params: { asset: "nope", component: "php", version: "1" }, headers: worker_auth, as: :json
    assert_response :unprocessable_entity
    get "/v1/ward/threats", headers: worker_auth
    assert_response :forbidden, "the worker posts probes; it does not read threats"

    post "/v1/ward/threats/#{id}/retriage", headers: auth, as: :json
    assert_equal "not_exposed", WardThreat.find(id).events.where(kind: "triaged").last.data["status"]
    assert_equal "exposed", body["status"], "a fix seen after triage is the resolver's to move, with fresh evidence"

    get "/v1/ward/threats/#{id}", headers: auth
    assert_response :ok
    assert body["history"].any? { |e| e["kind"] == "reported" }

    post "/v1/ward/threats/#{id}/accept_risk", params: {}, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/reason is required/, body["error"])
    post "/v1/ward/threats/#{id}/accept_risk", params: { reason: "for now" }, headers: auth, as: :json
    assert_equal "accepted_risk", body["status"]

    patch "/v1/ward/assets/#{coolify.id}", params: { components: %w[php laravel], exposure: "tailnet" }, headers: auth, as: :json
    assert_equal "tailnet", body["exposure"]
    get "/v1/ward/assets", headers: auth
    assert_equal [ "coolify" ], body.map { |a| a["name"] }

    _, agent_token = agent("skipsy", clearance: "personal")
    get "/v1/ward/threats", headers: { "Authorization" => "Bearer #{agent_token}" }
    assert_response :forbidden
  end
end
