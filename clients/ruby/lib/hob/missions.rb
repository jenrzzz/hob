module Hob
  # Work addressed to a principal. `lease_token` is present only on the
  # poller's own leased copy and is what the report-back calls need.
  class Mission < Record
    attribute :id, :assignee, :created_by, :title, :brief, :payload, :priority, :realm, :status, :attempts,
              :leased_at, :lease_expires_at, :lease_token, :result, :error, :request, :created_at, :updated_at

    def settled?
      %w[completed failed cancelled].include?(status)
    end

    def leased?
      status == "leased"
    end
  end

  # /v1/missions. Pollers lease, heartbeat, and complete or fail; people
  # create and cancel.
  class Missions
    def initialize(http)
      @http = http
    end

    # POST /v1/missions — a person's key.
    def create(assignee:, title:, brief: nil, payload: nil, priority: nil, realm: nil)
      Mission.new(@http.post("/v1/missions", { assignee: assignee, title: title, brief: brief, payload: payload,
                                               priority: priority, realm: realm }.compact))
    end

    def list(status: nil, assignee: nil)
      @http.get("/v1/missions", { status: status, assignee: assignee }).map { |m| Mission.new(m) }
    end

    # wait: long-poll for a result the way a creator would.
    def show(id, wait: nil)
      Mission.new(@http.get("/v1/missions/#{id}", { wait: wait }))
    end

    # POST /v1/missions/lease → the next mission for this key's principal,
    # or nil when the queue is empty. wait: seconds hob may hold the call
    # (up to 30); lease: seconds before an unreported mission is requeued.
    def lease(wait: nil, lease: nil)
      data = @http.post("/v1/missions/lease", { wait: wait, lease: lease }.compact)
      data["status"] == "empty" ? nil : Mission.new(data)
    end

    def heartbeat(mission, lease: nil)
      Mission.new(@http.post("/v1/missions/#{mission.id}/heartbeat", { lease_token: mission.lease_token, lease: lease }.compact))
    end

    def complete(mission, result)
      Mission.new(@http.post("/v1/missions/#{mission.id}/complete", { lease_token: mission.lease_token, result: result }))
    end

    def fail(mission, error)
      Mission.new(@http.post("/v1/missions/#{mission.id}/fail", { lease_token: mission.lease_token, error: error.to_s }))
    end

    def cancel(id)
      Mission.new(@http.post("/v1/missions/#{id}/cancel", nil))
    end

    # The worker loop: lease, yield, complete with the block's value (or
    # fail with the exception). Runs until `once:` or the block throws
    # :stop; returns the number of missions handled.
    #
    #   hob.missions.work(wait: 25) { |mission| Kitchen.run(mission.payload) }
    def work(wait: 25, lease: nil, once: false)
      handled = 0
      catch(:stop) do
        loop do
          mission = lease(wait: wait, lease: lease)
          if mission
            begin
              complete(mission, yield(mission))
            rescue StandardError => e
              fail(mission, "#{e.class}: #{e.message}")
              raise if e.is_a?(Hob::Error) && !e.is_a?(Hob::Invalid)
            end
            handled += 1
          end
          break if once
        end
      end
      handled
    end
  end
end
