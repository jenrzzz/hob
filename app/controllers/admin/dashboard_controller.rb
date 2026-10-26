module Admin
  # hob at a glance: what is waiting on a person, how the ward's watch is
  # going, what the agents are doing and what it all cost. Every number
  # links to the page (or names the rake task) that acts on it; this page
  # only shows. RLS tables read at the person's clearance, like every page.
  class DashboardController < BaseController
    def index
      now = Time.current
      @now = now

      @requests = SentinelRequest.pending.recent.includes(:capability, :principal).limit(5)
      @requests_waiting = SentinelRequest.pending.count
      @petitions_waiting = Petition.where(status: %w[pending failed]).count
      @frozen = Principal.where.not(capabilities_frozen_at: nil).order(:name)
      @proposals = WardThreat.open.select { |t| t.pending_proposals.any? }

      @checks = WardCheck.order(:slug).to_a
      @findings = WardFinding.open.group(:level).count
      @acknowledged = WardFinding.acknowledged.count
      @worst_findings = WardFinding.open.by_severity.includes(:check).limit(5)
      @threats = WardThreat.open.where.not(status: %w[not_exposed accepted_risk expired]).by_severity.limit(8)
      @triage = WardRun.where.not(triage: nil).recent.first

      @missions = Mission.group(:status).count
      @open_missions = Mission.open.includes(:assignee).order(priority: :desc, created_at: :asc).limit(8)
      @failed_missions = Mission.where(status: "failed", updated_at: 7.days.ago..).includes(:assignee).order(updated_at: :desc).limit(5)
      @agents = Principal.agents.includes(:api_keys).order(:name)

      day = SentinelRequest.where(created_at: 24.hours.ago..)
      @sentinel_day = day.group(:status).count
      @top_capabilities = SentinelRequest.where(created_at: 7.days.ago..).joins(:capability)
                                         .group("capabilities.name").order(Arel.sql("count(*) DESC")).limit(6).count

      @usage = { "Today" => now.beginning_of_day, "7 days" => 7.days.ago, "30 days" => 30.days.ago }
               .transform_values { |since| UsageEvent.summarize(UsageEvent.since(since)) }
      @models = UsageEvent.since(30.days.ago).group(:model).order(Arel.sql("count(*) DESC")).limit(6)
                          .pluck(:model, Arel.sql("count(*)"), Arel.sql("coalesce(sum(cost), 0)"))
      @usage_errors = UsageEvent.since(24.hours.ago).where.not(status: "success").order(created_at: :desc).limit(5)

      @schedules = Schedule.enabled.includes(:assignee).order(:next_fire_at).limit(6)
      @skipping = Schedule.enabled.where.not(last_skipped_at: nil).where("last_fired_at IS NULL OR last_skipped_at > last_fired_at").includes(:assignee)

      @loops = People.loops("limit" => 5)
      @situation = Situation.get({}, requester: current_person, surface: "admin", now: now)["people"].first
      @board = BoardPost.order(created_at: :desc).includes(:sender_agent).limit(6)
      @devices = Device.of_people.includes(:principal).order(last_seen_at: :desc)

      @counts = {
        "People" => Person.live.count, "Conversations" => Conversation.chats.count, "Record collections" => RecordCollection.live.count,
        "Records" => Record.live.count, "Capabilities" => Capability.count, "Grants" => SentinelPolicy.count,
        "Schedules" => Schedule.enabled.count, "Principals" => Principal.count
      }
    end
  end
end
