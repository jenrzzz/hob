module Admin
  # What the forge has been building and how (SENTINEL.md, "Trajectories"):
  # its missions, newest first, and for any one of them the brief, the
  # report, and what Claude Code did, step by step. Read at the person's
  # clearance: a mission above it, or its sessions, is not there.
  class ForgeController < BaseController
    PER_PAGE = 40
    KINDS = { "forge.capability" => "capability", "forge.upkeep" => "upkeep", "forge.commission" => "commission" }.freeze

    helper_method :kind_of, :duration_of, :clip, :headline

    def index
      @page = [ params[:page].to_i, 1 ].max
      scope = Mission.where("payload->>'kind' LIKE 'forge.%'")
      scope = scope.where("payload->>'kind' = ?", KINDS.key(params[:kind])) if KINDS.value?(params[:kind])
      scope = scope.where(status: params[:status]) if Mission::STATUSES.include?(params[:status])
      rows = scope.order(created_at: :desc, id: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      @more = rows.size > PER_PAGE
      @missions = rows.first(PER_PAGE)
      @sessions = MissionTrajectory.where(mission_id: @missions.map(&:id)).group(:mission_id).count
    end

    def show
      @mission = forge_mission
      @trajectories = @mission.trajectories.in_order.select(:id, :mission_id, :session, :path, :lines, :bytes, :attempt, :created_at).to_a
      chosen = @trajectories.find { |t| t.id == params[:session] } || @trajectories.reject(&:side?).last || @trajectories.last
      return if chosen.nil?

      @trajectory = @mission.trajectories.find(chosen.id)
      @steps, @skipped = Trajectories.steps(@trajectory.jsonl)
    end

    # The session file as Claude Code wrote it.
    def raw
      trajectory = forge_mission.trajectories.find(params[:trajectory])
      send_data trajectory.jsonl, filename: "#{trajectory.mission_id}-#{trajectory.path.tr('/', '-')}", type: "application/x-ndjson", disposition: "attachment"
    end

    private

    def forge_mission
      Mission.where("payload->>'kind' LIKE 'forge.%'").find(params[:id])
    end

    def kind_of(mission)
      KINDS.fetch(mission.payload["kind"], mission.payload["kind"].to_s)
    end

    # How long the mission was held, for one that has been leased.
    def duration_of(mission)
      return nil if mission.leased_at.nil?

      seconds = ((mission.settled? ? mission.updated_at : Time.current) - mission.leased_at).to_i
      seconds < 90 ? "#{seconds}s" : "#{(seconds / 60.0).round}m"
    end

    def clip(text, limit = Trajectories::CLIP)
      Trajectories.clip(text, limit)
    end

    def headline(step)
      Trajectories.headline(step)
    end
  end
end
