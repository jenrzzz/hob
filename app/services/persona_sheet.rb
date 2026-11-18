# A persona's mutable self-description (MEMORY.md, "The sheet"): sections of
# short entries (name, tastes, stance, decided, ...) that accrete from
# evidence. Every change is a PersonaSheetRevision citing the observations
# that justify it; nothing changes until a revision is applied; any applied
# revision can be rolled back. The constitution (`prompt.system_core`) is not
# a section and cannot be reached from here.
#
# The sheet is per clearance, like DESIGN.md's digests: a revision carries
# the realm it was proposed at, and the sheet a reader sees is the applied
# revisions at or below their clearance, replayed in the order they were
# applied. An intimate revision that removes a household entry removes it
# only for intimate readers.
class PersonaSheet
  OPS = %w[add remove replace set].freeze
  RESERVED = %w[system_core constitution prompt instruction].freeze
  SECTION_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/
  TEXT_LIMIT = 500
  MAX_OPS = 20

  Entry = Struct.new(:id, :text, :realm, :revision, keyword_init: true)

  attr_reader :persona

  def self.validate_ops!(ops)
    ops = Array(ops)
    raise Gateway::Invalid, "a revision has 1 to #{MAX_OPS} ops" if ops.empty? || ops.size > MAX_OPS

    ops.each_with_index do |raw, i|
      op = raw.to_h.stringify_keys
      unknown = op.keys - %w[op section entry text]
      raise Gateway::Invalid, "op #{i}: unknown field #{unknown.join(', ')}" if unknown.any?
      raise Gateway::Invalid, "op #{i}: op is #{OPS.join(', ')}" unless OPS.include?(op["op"])

      section = op["section"].to_s
      if RESERVED.include?(section)
        raise Gateway::Invalid, "op #{i}: #{section} is the persona's constitution and is not on the sheet"
      end
      raise Gateway::Invalid, "op #{i}: section is a lowercase word (tastes, stance, decided, ...)" unless section.match?(SECTION_FORMAT)
      if %w[add replace set].include?(op["op"]) && (op["text"].to_s.strip.empty? || op["text"].to_s.length > TEXT_LIMIT)
        raise Gateway::Invalid, "op #{i}: text is 1 to #{TEXT_LIMIT} characters"
      end
      raise Gateway::Invalid, "op #{i}: #{op['op']} names the entry it changes" if %w[remove replace].include?(op["op"]) && op["entry"].blank?
    end
    ops
  end

  def initialize(persona)
    @persona = persona
  end

  # { section => [Entry] } as of now (or as of `version`), at this clearance.
  def state(version: nil)
    sections = {}
    scope = persona.sheet_revisions.where(kind: "edit").where(status: %w[applied]).order(:applied_seq)
    scope = scope.where(version: ..version) if version
    scope.each { |rev| replay(sections, rev) }
    sections.reject { |_, entries| entries.empty? }
  end

  # The highest applied version visible here (0: an empty sheet).
  def version
    persona.sheet_revisions.where(status: "applied").maximum(:version) || 0
  end

  def as_json(version: nil)
    { persona: persona.key, version: version || self.version,
      sections: state(version: version).transform_values { |es| es.map { |e| { id: e.id, text: e.text, realm: e.realm } } } }
  end

  # The sheet as the persona stage renders it, after the constitution.
  def render
    sections = state
    return nil if sections.empty?

    body = sections.map { |name, entries| "### #{name}\n#{entries.map { |e| "- #{e.text}" }.join("\n")}" }.join("\n\n")
    "## Who you are now\n\n(What you have come to know about yourself; it grows from what you notice.)\n\n#{body}"
  end

  # A revision, proposed and not yet applied. Realm: the request's clearance.
  def propose!(ops:, citations:, rationale: nil, via: Current.surface, provenance: {}, realm: Clearance.current)
    ops = self.class.validate_ops!(ops).map { |op| op.to_h.stringify_keys.slice("op", "section", "entry", "text") }
    citations = Array(citations).map(&:to_s).uniq
    raise Gateway::Invalid, "a revision cites the observations that justify it" if citations.empty?

    visible = Observation.where(id: citations).pluck(:id)
    missing = citations - visible
    raise Gateway::Invalid, "no observation #{missing.join(', ')} at this clearance" if missing.any?

    check_entries!(ops, realm: realm)
    with_next_version do |_|
      persona.sheet_revisions.create!(
        kind: "edit", realm: realm, ops: ops, rationale: rationale, citations: citations,
        status: "proposed", proposed_by: Current.principal, proposed_via: via.presence || "hob",
        provenance: provenance, created_at: Time.current
      )
    end
  end

  def apply!(revision)
    raise Gateway::Invalid, "revision #{revision.version} is #{revision.status}" unless %w[proposed reverted].include?(revision.status)
    raise Gateway::Invalid, "a rollback is applied when it is made" if revision.kind == "rollback"

    check_entries!(revision.ops, realm: revision.realm)
    revision.update!(status: "applied", decided_by: Current.principal, decided_at: Time.current,
                     applied_seq: next_applied_seq, reverted_by_id: nil)
    revision
  end

  def reject!(revision)
    raise Gateway::Invalid, "revision #{revision.version} is #{revision.status}" unless revision.status == "proposed"

    revision.update!(status: "rejected", decided_by: Current.principal, decided_at: Time.current)
  end

  # Back to how the sheet was at `version`: every applied edit after it is
  # reverted (and can be applied again), and the rollback is its own
  # revision, so the history says who did it. Only what this clearance can
  # see is reverted.
  def rollback!(to:, rationale: nil)
    to = Integer(to)
    raise Gateway::Invalid, "version must be 0 or more" if to.negative?

    later = persona.sheet_revisions.where(kind: "edit", status: "applied").where("version > ?", to).to_a
    PersonaSheetRevision.transaction do
      rollback = with_next_version do |_|
        persona.sheet_revisions.create!(
          kind: "rollback", realm: Clearance.current, ops: [], rationale: rationale,
          citations: [], status: "applied", rollback_to: to, proposed_by: Current.principal,
          proposed_via: Current.surface || "hob", decided_by: Current.principal, decided_at: Time.current,
          applied_seq: next_applied_seq, provenance: { "reverted" => later.map(&:version) }, created_at: Time.current
        )
      end
      later.each { |rev| rev.update!(status: "reverted", reverted_by_id: rollback.id) }
      rollback
    end
  end

  private

  def replay(sections, rev)
    rev.ops.each_with_index do |op, i|
      entries = (sections[op["section"]] ||= [])
      id = "#{rev.id}.#{i}"
      case op["op"]
      when "add" then entries << Entry.new(id: id, text: op["text"], realm: rev.realm, revision: rev.version)
      when "set" then entries.replace([ Entry.new(id: id, text: op["text"], realm: rev.realm, revision: rev.version) ])
      when "remove" then entries.reject! { |e| e.id == op["entry"] }
      when "replace"
        at = entries.index { |e| e.id == op["entry"] }
        entries[at] = Entry.new(id: id, text: op["text"], realm: rev.realm, revision: rev.version) if at
      end
    end
  end

  # remove and replace must name an entry the sheet holds at the revision's
  # realm, in that section.
  def check_entries!(ops, realm:)
    targets = ops.select { |op| %w[remove replace].include?(op["op"]) }
    return if targets.empty?

    current = Clearance.with(realm) { state }
    targets.each do |op|
      next if Array(current[op["section"]]).any? { |e| e.id == op["entry"] }

      raise Gateway::Invalid, "no entry #{op['entry']} in #{op['section']} on #{persona.key}'s sheet"
    end
  end

  # Versions come from a sequence shared by every persona and realm (the
  # column default), so numbering never collides with a revision this
  # clearance cannot see, and a gap says nothing about whose sheet changed.
  def with_next_version
    yield nil
  end

  def next_applied_seq
    ActiveRecord::Base.connection.select_value("SELECT nextval('persona_sheet_applied_seq')").to_i
  end
end
