# hob's clock (SCHEDULES.md): a mission template and a cron line. When it
# comes due, the tick (ScheduleTickJob, every minute) queues the mission for
# its assignee exactly as if someone had asked just then, so whoever does
# the work needs nothing new: it leases, works, and completes as always.
#
# A schedule fires at most once per tick and never catches up: hob down for
# a day means one mission when it is back, not a backlog. And it never
# stacks: if the last mission it queued is still open, the firing is
# skipped and counted, and whoever owns the schedule hears about the first
# skip of a streak, since a worker that stopped leasing must not look like
# a quiet week.
class Schedule < ApplicationRecord
  NAME = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
  # An agent's schedule may fire at most this often; a person's, every minute.
  MIN_AGENT_INTERVAL = 15.minutes
  MAX_PER_AGENT = 25

  belongs_to :assignee, class_name: "Principal"
  belongs_to :created_by, class_name: "Principal", optional: true
  has_many :missions, dependent: :nullify

  validates :name, format: { with: NAME, message: "is lowercase letters, digits, '.', '_' and '-'" },
                   uniqueness: { scope: :created_by_id }
  validates :title, :realm, presence: true
  validate :cron_parses, :time_zone_known, :realm_visible_to_assignee, :often_enough_for_an_agent

  before_create { self.id ||= ULID.generate }
  before_save :plan, if: -> { new_record? || will_save_change_to_cron? || will_save_change_to_time_zone? || will_save_change_to_enabled? }

  scope :enabled, -> { where(enabled: true) }
  scope :due, ->(now = Time.current) { enabled.where(next_fire_at: ..now) }

  # Fire every schedule that is due, one row at a time so a slow insert does
  # not hold the others, and SKIP LOCKED so two tickers never fire one
  # schedule twice. -> [[schedule, mission or nil (skipped)], ...]
  def self.tick!(now: Time.current)
    fired = []
    loop do
      pair = transaction do
        schedule = due(now).order(:next_fire_at).lock("FOR UPDATE SKIP LOCKED").first
        schedule && [ schedule, schedule.fire!(now: now) ]
      end
      break if pair.nil?

      fired << pair
    end
    fired
  end

  # The cron line read in the schedule's zone. fugit reads a line with no
  # zone of its own in the process's zone, whatever `from` is in, so the
  # zone goes into the line (one that names its own zone keeps it).
  def parsed_cron
    return if cron.blank?

    parsed = Fugit.parse_cronish(cron.to_s)
    return parsed if parsed.nil? || parsed.timezone || !EtOrbi.get_tzone(time_zone)

    Fugit::Cron.parse("#{parsed.to_cron_s} #{time_zone}")
  end

  # The first firing strictly after `time`.
  def next_after(time)
    parsed_cron&.next_time(EtOrbi::EoTime.new(time.to_f, time_zone))&.to_t&.utc
  end

  # Seconds between firings, roughly (fugit's estimate; exact for most lines).
  def interval
    parsed_cron&.rough_frequency
  end

  def last_mission
    last_mission_id && Mission.find_by(id: last_mission_id)
  end

  # Queue the mission, or skip because the last one is still open; either
  # way, move on to the next firing after `now`.
  def fire!(now: Time.current)
    self.next_fire_at = next_after(now)
    if (open = last_mission) && !open.settled?
      streak = last_skipped_at.nil? || (last_fired_at && last_skipped_at < last_fired_at)
      update!(skipped_count: skipped_count + 1, last_skipped_at: now)
      warn_stuck!(open) if streak
      return nil
    end

    mission = missions.create!(assignee: assignee, created_by: created_by, title: title, brief: brief,
                               payload: payload, priority: priority, realm: realm)
    update!(last_fired_at: now, last_mission_id: mission.id, fired_count: fired_count + 1)
    mission
  end

  def as_json_for_hob
    {
      "id" => id, "name" => name, "description" => description.presence, "cron" => cron, "time_zone" => time_zone,
      "assignee" => assignee.name, "created_by" => created_by&.name, "realm" => realm,
      "title" => title, "brief" => brief, "payload" => payload, "priority" => priority, "enabled" => enabled?,
      "next_fire_at" => next_fire_at&.utc&.iso8601, "last_fired_at" => last_fired_at&.utc&.iso8601,
      "last_mission" => last_mission_id, "fired_count" => fired_count, "skipped_count" => skipped_count,
      "last_skipped_at" => last_skipped_at&.utc&.iso8601
    }.compact
  end

  private

  def plan
    self.next_fire_at = enabled? ? next_after(Time.current) : nil
  end

  # To whoever made the schedule, on their channel; to the household when
  # hob made it (a rake task, a ward setup).
  def warn_stuck!(open)
    title = "hob: #{name} skipped; #{assignee.name} has not finished the last one"
    body = "#{open.title} has been #{open.status} since #{open.created_at.utc.iso8601} (mission #{open.id}). " \
           "The schedule fires again at #{next_fire_at&.utc&.iso8601 || 'never'}."
    if created_by&.trusted? || created_by.nil?
      Notify.person(title: title, body: body, tags: "hourglass")
    else
      Notify.principal(created_by, title: title, body: body, tags: "hourglass")
    end
  end

  def cron_parses
    errors.add(:cron, "is not a cron line fugit understands (\"0 7 * * *\", \"every day at 7am\")") if cron.present? && parsed_cron.nil?
    errors.add(:cron, "can't be blank") if cron.blank?
  end

  def time_zone_known
    EtOrbi.get_tzone(time_zone) || errors.add(:time_zone, "#{time_zone.inspect} is not a time zone")
  end

  def realm_visible_to_assignee
    return if assignee.nil? || realm.blank?

    errors.add(:realm, "#{realm} is above #{assignee.name}'s clearance") if Realm.rank_of(assignee.max_clearance) < Realm.rank_of(realm)
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def often_enough_for_an_agent
    return unless created_by&.agent? && interval

    errors.add(:cron, "fires more often than every #{MIN_AGENT_INTERVAL.inspect}") if interval < MIN_AGENT_INTERVAL
  end
end
