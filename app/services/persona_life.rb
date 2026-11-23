# A persona's life between conversations (MELUZINA.md, "A persona's life").
# `personas.life`:
#
#   { "instruction" => "...",            how her life turns are written (required)
#     "realm" => "personal",             where her life is kept (default personal)
#     "zone" => "America/Chicago",       whose hours the odds are in (default UTC)
#     "odds" => { "0-5" => 0.2, ... },   chance per 15-minute check, by local hour (default 0.1)
#     "min_gap_minutes" => 180,          never two beats closer than this
#     "role" => "...",                   model role (default the persona's)
#     "max_iterations" => 24,            tool rounds a beat may take (default ToolExchange's); a life
#                                        with a machine to tinker on wants more than a diary needs
#     "beats" => { lane => [direction, ...] },   where a beat may go, drawn avoiding recent lanes
#     "paper" => { "url" => <JSON Feed>, "odds" => 3, "skip" => 1 },  read on one beat in `odds`,
#                                        past the first `skip` items (a briefing)
#     "dial" => "off" | "rare" | "daily",          how often a whisper may go out
#     "home" => <conversation id> }      where whispers land; set at the box (hob:persona:home)
#
# Her life is observations she authors about herself, at the life's realm:
# `diary` (one per beat), `mood` (superseded each beat), `chew` (the one
# thing she sits with: superseded as it moves, retired when put down). A
# whisper is an assistant node appended to her home conversation with
# meta.whisper, which a bridge following that conversation delivers.
#
# Nothing here names a persona; the instruction and the beats are hers,
# pushed with the rest of her.
class PersonaLife
  class Invalid < StandardError; end

  OPTIONS = %w[instruction realm zone odds min_gap_minutes role max_iterations note beats paper dial home].freeze
  MAX_ITERATIONS = 60
  DIALS = %w[off rare daily].freeze
  COOLDOWNS = { "rare" => 60.hours, "daily" => 18.hours }.freeze
  DEFAULT_ODDS = 0.1
  DEFAULT_GAP = 180

  DIARY_MAX = 500
  DIARY_SHOWN = 3
  DIARY_SHOWN_CHARS = 220
  WHISPER_MAX = 200
  OBSESSION_MAX = 80
  OBSESSION_BEATS_MAX = 8
  CHEW_SUBJECT_MAX = 120
  CHEW_NOTE_MAX = 400
  CHEW_TAKE_MAX = 1800
  CHEW_NOTES_MAX = 8
  CHEW_STALE = 4.days
  CHEW_EXPIRE = 8.days
  CHEW_SOURCES = %w[paper house conversation archive].freeze
  AVOID_RECENT_LANES = 4
  PRESENCE_WINDOW = 12.hours
  # A user line this recent means a turn may be under way in the home
  # conversation; a whisper appended now could land off the branch.
  TALKING_WINDOW = 2.minutes

  # Checks a persona's `life` config. -> problems, empty when it reads.
  def self.problems(config)
    config = config.to_h.stringify_keys
    return [] if config.empty?

    problems = []
    unknown = config.keys - OPTIONS
    problems << "life has unknown keys: #{unknown.join(', ')}" if unknown.any?
    problems << "life.instruction is required" if config["instruction"].blank?
    begin
      Realm.rank_of(config["realm"]) if config["realm"].present?
    rescue ArgumentError, KeyError
      problems << "life.realm #{config['realm']} is not a realm"
    end
    if config["zone"].present? && ActiveSupport::TimeZone[config["zone"].to_s].nil?
      problems << "life.zone #{config['zone']} is not a time zone"
    end
    problems << "life.dial is off, rare or daily" if config["dial"].present? && !DIALS.include?(config["dial"])
    problems << "life.odds maps hour ranges (\"0-5\") to chances" unless odds_read?(config["odds"])
    problems << "life.beats maps lanes to lists of directions" unless beats_read?(config["beats"])
    rounds = config["max_iterations"]
    unless rounds.nil? || (rounds.is_a?(Integer) && rounds.between?(2, MAX_ITERATIONS))
      problems << "life.max_iterations is a whole number from 2 to #{MAX_ITERATIONS}"
    end
    note = config["note"]
    unless note.nil? || (note.is_a?(String) && note.strip.present? && note.length <= Shells::MAX_PATH && !note.match?(/[\0\r\n]/))
      problems << "life.note is the path of a file on her machine"
    end
    paper = config["paper"]
    problems << "life.paper needs a url" if paper.present? && (!paper.is_a?(Hash) || paper["url"].blank?)
    problems
  end

  def self.odds_read?(odds)
    return true if odds.nil?
    return false unless odds.is_a?(Hash)

    odds.all? { |range, chance| range.to_s.match?(/\A\d{1,2}(-\d{1,2})?\z/) && chance.is_a?(Numeric) && chance.between?(0, 1) }
  end

  def self.beats_read?(beats)
    return true if beats.nil?

    beats.is_a?(Hash) && beats.all? { |lane, dirs| lane.present? && dirs.is_a?(Array) && dirs.all? { |d| d.is_a?(String) && d.present? } }
  end

  def self.living
    Persona.where("life ? 'instruction'")
  end

  attr_reader :persona, :config

  def initialize(persona)
    @persona = persona
    @config = persona.life.to_h.stringify_keys
  end

  def realm
    config["realm"].presence || "personal"
  end

  def zone
    ActiveSupport::TimeZone[config["zone"].presence || "UTC"]
  end

  def dial
    DIALS.include?(config["dial"]) ? config["dial"] : "off"
  end

  # Tool rounds one beat may take.
  def max_iterations
    config["max_iterations"].presence&.to_i || ToolExchange::DEFAULT_MAX_ITERATIONS
  end

  # A file on her machine she keeps for herself (where a build stands, what
  # is next), whose top a beat reads back to her; nil when she keeps none.
  def note
    config["note"].presence
  end

  # The agent this persona acts as (AgentTools), or nil.
  def agent
    return @agent if defined?(@agent)

    name = persona.tools.to_h.stringify_keys["agent"].presence
    @agent = name && Principal.find_by(name: name, kind: "agent")
  end

  # Her home conversation is usually above her life's realm (the Discord DM
  # runs at intimate). Her life may see that it exists, when he last wrote
  # and when she last whispered, and may append a whisper to it; it reads
  # the home's words only when the home is at or below the life's realm
  # (home_readable?), since what a beat reads lands in its own conversation.
  def home
    return @home if defined?(@home)

    @home = config["home"].presence && at_home { Conversation.find_by(id: config["home"]) }
  end

  def home_readable?
    home.present? && Realm.rank_of(home.realm) <= Realm.rank_of(realm)
  end

  def at_home(&)
    Clearance.with(Realm.order(rank: :desc).first.slug, &)
  end

  def entity
    @entity ||= persona.memory_entity
  end

  # --- reading her life (at the caller's clearance) -----------------------

  def mine(kind)
    Observation.current.where(entity_id: entity.id, author_entity_id: entity.id, kind: kind, realm: realm)
  end

  # Newest first.
  def diary(limit = DIARY_SHOWN)
    mine("diary").order(observed_at: :desc).limit(limit).to_a
  end

  def mood
    mine("mood").order(observed_at: :desc).first
  end

  def chew
    mine("chew").order(observed_at: :desc).first
  end

  def last_beat_at
    mine("diary").maximum(:observed_at)
  end

  # How many beats in a row the mood has carried this obsession.
  def obsession_beats(current = mood)
    handle = current&.source&.dig("obsession")
    return 0 if handle.blank?

    beats = 1
    prev = current
    while (prev = prev.supersedes_id && Observation.find_by(id: prev.supersedes_id)) && prev.source&.dig("obsession") == handle
      beats += 1
      break if beats > OBSESSION_BEATS_MAX
    end
    beats
  end

  def obsession_spent?(current = mood)
    obsession_beats(current) >= OBSESSION_BEATS_MAX
  end

  def recent_lanes
    mine("diary").order(observed_at: :desc).limit(AVOID_RECENT_LANES).filter_map { |o| o.source&.dig("lane") }
  end

  # Her life as she carries it, for kat or a bridge to show (GET life).
  def as_json(*)
    now = Time.current
    current_mood = mood
    current_chew = chew
    {
      "realm" => realm, "dial" => dial, "home" => config["home"],
      "last_beat_at" => last_beat_at&.utc&.iso8601, "last_whisper_at" => last_whisper&.created_at&.utc&.iso8601,
      "diary" => diary(60).reverse.map do |o|
        { "id" => o.id, "entry" => o.body, "at" => o.observed_at.utc.iso8601, "lane" => o.source&.dig("lane") }.compact
      end,
      "mood" => current_mood && {
        "id" => current_mood.id, "disposition" => current_mood.body, "at" => current_mood.observed_at.utc.iso8601,
        "obsession" => (obsession_spent?(current_mood) ? nil : current_mood.source&.dig("obsession")),
        "obsession_beats" => obsession_beats(current_mood),
        "manifestation" => current_mood.source&.dig("manifestation")
      }.compact,
      "chew" => current_chew && chew_json(current_chew, now)
    }
  end

  def chew_json(observation, now = Time.current)
    source = observation.source.to_h
    { "id" => observation.id, "subject" => source["subject"], "from" => source["from"], "take" => observation.body,
      "notes" => Array(source["notes"]), "picked_up_at" => source["picked_up_at"],
      "moved_at" => observation.observed_at.utc.iso8601,
      "stale" => observation.observed_at < now - CHEW_STALE, "worn_out" => Array(source["notes"]).size >= CHEW_NOTES_MAX }.compact
  end

  # Her day, for the persona stage of a conversation turn: what she has
  # been doing, her mood, and what she is chewing on. Second person, like
  # her system core.
  def render
    parts = []
    current_mood = mood
    parts << "- Mood: #{current_mood.body}" if current_mood
    handle = current_mood&.source&.dig("obsession")
    parts << "- Current obsession: #{handle}" if handle.present? && !obsession_spent?(current_mood)
    entries = diary(DIARY_SHOWN).reverse
    if entries.any?
      parts << "- Lately (your diary, oldest first):"
      entries.each { |o| parts << "  - #{o.body.to_s.truncate(DIARY_SHOWN_CHARS)}" }
    end
    if (current = chew)
      source = current.source.to_h
      parts << "- What you've been chewing on: #{source['subject']}"
      parts << "  The take as it stands:\n#{current.body.to_s.lines.map { |l| "    #{l}" }.join}" if current.body.present?
    end
    return nil if parts.empty?

    "## Your own life lately\n\n(Your life between conversations, kept by hob.)\n\n#{parts.join("\n")}"
  end

  # --- writing her life ----------------------------------------------------

  def write_diary!(entry, lane: nil, at: Time.current)
    Memory.remember!(about: entity, author: entity, kind: "diary", body: entry.to_s.strip.truncate(DIARY_MAX),
                     realm: realm, observed_at: at, source: { "lane" => lane }.compact)
  end

  def set_mood!(disposition:, obsession: nil, manifestation: nil, at: Time.current)
    raise Invalid, "a mood needs a disposition" if disposition.blank?

    source = { "obsession" => obsession.to_s.strip.truncate(OBSESSION_MAX).presence,
               "manifestation" => (manifestation.to_f.clamp(0.0, 1.0) if manifestation.is_a?(Numeric)) }.compact
    current = mood
    if current
      replacement = Memory.supersede!(current, body: disposition.to_s.strip, realm: realm, reason: "a new beat")
      replacement.update_columns(source: source, observed_at: at)
      replacement
    else
      Memory.remember!(about: entity, author: entity, kind: "mood", body: disposition.to_s.strip, realm: realm,
                       observed_at: at, source: source)
    end
  end

  # action: pick_up (puts any current one down), chew (it moved), spit_out.
  def chew!(action:, subject: nil, from: nil, note: nil, take: nil, at: Time.current)
    current = chew
    case action.to_s
    when "pick_up"
      raise Invalid, "pick_up needs a subject" if subject.blank?

      Memory.retire!(current, reason: "picked up something else", realm: realm) if current
      notes = note.present? ? [ { "note" => note.to_s.strip.truncate(CHEW_NOTE_MAX), "at" => at.utc.iso8601 } ] : []
      body = take.present? ? take.to_s.strip.truncate(CHEW_TAKE_MAX) : subject.to_s.strip
      Memory.remember!(about: entity, author: entity, kind: "chew", body: body,
                       realm: realm, observed_at: at,
                       source: { "subject" => subject.to_s.strip.truncate(CHEW_SUBJECT_MAX),
                                 "from" => (CHEW_SOURCES.include?(from.to_s) ? from.to_s : nil),
                                 "notes" => notes, "picked_up_at" => at.utc.iso8601 }.compact)
    when "chew"
      raise Invalid, "she isn't chewing on anything" if current.nil?

      source = current.source.to_h
      notes = Array(source["notes"])
      notes += [ { "note" => note.to_s.strip.truncate(CHEW_NOTE_MAX), "at" => at.utc.iso8601 } ] if note.present?
      body = take.present? ? take.to_s.strip.truncate(CHEW_TAKE_MAX) : current.body
      replacement = Memory.supersede!(current, body: body, realm: realm, reason: "it moved")
      replacement.update_columns(source: source.merge("notes" => notes.last(CHEW_NOTES_MAX)), observed_at: at)
      replacement
    when "spit_out"
      raise Invalid, "she isn't chewing on anything" if current.nil?

      Memory.retire!(current, reason: "put down", realm: realm)
    else
      raise Invalid, "action is pick_up, chew or spit_out"
    end
  end

  # A chew nobody touched for CHEW_EXPIRE is already gone.
  def expire_chew!(now = Time.current)
    current = chew
    Memory.retire!(current, reason: "went cold", realm: realm) if current && current.observed_at < now - CHEW_EXPIRE
  end

  # --- whispers ------------------------------------------------------------

  def last_whisper
    return nil unless home

    at_home { home.message_nodes.where("meta @> ?", { whisper: true }.to_json).order(created_at: :desc).first }
  end

  def last_seen_at
    return nil unless home

    at_home { home.message_nodes.where(role: "user").maximum(:created_at) }
  end

  # Why a whisper can't go out now, or nil when it may.
  def whisper_blocked(now = Time.current)
    return "whispers are off" if dial == "off"
    return "she has no home conversation to whisper into" if home.nil?

    seen = last_seen_at
    return "he is talking with her right now" if seen && seen > now - TALKING_WINDOW

    last = last_whisper
    return nil if last.nil? || last.created_at <= now - COOLDOWNS.fetch(dial)
    return nil if seen && seen > last.created_at

    "she whispered recently and he hasn't been by since"
  end

  # -> the whisper's node. Raises Invalid with the reason it can't go.
  def whisper!(body, now: Time.current)
    text = body.to_s.strip.truncate(WHISPER_MAX)
    raise Invalid, "a whisper needs words" if text.blank?
    if (reason = whisper_blocked(now))
      raise Invalid, reason
    end

    conversation = home
    at_home do
      branch = conversation.branch
      branch.with_lock do
        node = MessageNode.append!(conversation: conversation, parent_hash: branch.head_hash, role: "assistant",
                                   content: text, meta: { "whisper" => true, "persona" => persona.key })
        branch.advance!(node)
        conversation.touch
        node
      end
    end
  end

  # --- the beat ------------------------------------------------------------

  # Whether a beat is due now: past the gap, and the hour's odds come up.
  def due?(now: Time.current, rng: Random)
    last = last_beat_at
    gap = (config["min_gap_minutes"] || DEFAULT_GAP).to_i.minutes
    return false if last && last > now - gap

    rng.rand < chance_at(now.in_time_zone(zone).hour)
  end

  def chance_at(hour)
    odds = config["odds"].to_h
    hit = odds.find do |range, _|
      from, to = range.to_s.split("-").map(&:to_i)
      (from..(to || from)).cover?(hour)
    end
    hit ? hit.last.to_f : DEFAULT_ODDS
  end

  # Run one beat: a completion under her persona and the life instruction,
  # with her life's tools, her agent's, and her corpora. -> Completion::Result
  def beat!(now: Time.current, rng: Random.new)
    Clearance.with(realm) do
      Current.set(surface: "life", clearance: realm) do
        expire_chew!(now)
        Beat.new(self, now: now, rng: rng).run!
      end
    end
  end
end
