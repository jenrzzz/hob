module Assembly
  # Who a persona is talking to, kept apart from who she is (MELUZINA.md,
  # "Who she is talking to"). A persona's `system_core` says who she is and
  # holds for anyone; `prompt.relations` says who a particular someone is to
  # her:
  #
  #   { "principal:jenner" => "Jenner, her closest thinking-partner ...",
  #     "*" => "Someone who is not Jenner ..." }
  #
  # The other party of a turn is the key's principal, unless a person's key
  # names someone else with `with:` (a bridge carrying another speaker, a
  # person letting an agent or a persona talk to her). An agent's key cannot
  # run a turn at all, so nobody names themselves.
  #
  #   with: "principal:skipsy" | "persona:kat-presence"     someone hob knows
  #   with: { "name" => "Claude", "about" => "..." }        a guest it doesn't
  #
  # A turn nobody is on the other end of (a beat of her life, a job) has no
  # counterpart, and nothing is rendered.
  class Counterpart
    ANYONE = "*".freeze
    KINDS = %w[principal persona].freeze
    REF = /\A(#{KINDS.join('|')}):[A-Za-z0-9][A-Za-z0-9_.-]*\z/
    ABOUT_MAX = 600
    NAME_MAX = 80

    DESCRIBED = {
      "human" => "a person of the household", "agent" => "an agent", "worker" => "one of hob's workers",
      "persona" => "another persona", "guest" => "a guest hob does not know, named by a person of the household"
    }.freeze

    attr_reader :ref, :name, :kind, :about

    # Checks a persona's `prompt.relations`. -> problems, empty when it reads.
    def self.problems(relations)
      return [] if relations.nil?
      return [ "relations must be a map of who to what they are to her" ] unless relations.is_a?(Hash)

      relations.flat_map do |ref, text|
        [
          ("relations: #{ref} is not principal:<name>, persona:<key> or #{ANYONE}" unless ref == ANYONE || ref.to_s.match?(REF)),
          ("relations: #{ref} must be text" unless text.is_a?(String) && text.strip.present?)
        ].compact
      end
    end

    # The other party of the request in progress. named: a turn's `with:`.
    def self.resolve(named = nil, principal: Current.principal)
      return of(principal) if named.blank?
      raise Gateway::Invalid, "with: needs a person's key" unless principal&.trusted?

      case named
      when String then known(named)
      when Hash, ActionController::Parameters then guest(named.to_h.stringify_keys)
      else raise Gateway::Invalid, "with is principal:<name>, persona:<key>, or { name, about }"
      end
    end

    def self.of(principal)
      principal && new(ref: "principal:#{principal.name}", name: principal.name, kind: principal.kind)
    end

    def self.known(ref)
      raise Gateway::Invalid, "with: #{ref} is not principal:<name> or persona:<key>" unless ref.match?(REF)

      kind, key = ref.split(":", 2)
      if kind == "persona"
        persona = Persona.find_by(key: key) or raise Gateway::Invalid, "with: no persona #{key}"
        new(ref: ref, name: persona.name, kind: "persona")
      else
        of(Principal.find_by(name: key)) or raise Gateway::Invalid, "with: no principal #{key}"
      end
    end

    def self.guest(named)
      unknown = named.keys - %w[name about]
      raise Gateway::Invalid, "unknown with option: #{unknown.join(', ')}" if unknown.any?

      name = named["name"].to_s.squish
      raise Gateway::Invalid, "with: a guest needs a name of 1 to #{NAME_MAX} characters" unless name.length.between?(1, NAME_MAX)

      new(ref: "guest:#{name.parameterize}", name: name, kind: "guest", about: named["about"].to_s.squish.truncate(ABOUT_MAX))
    end

    def initialize(ref:, name:, kind:, about: nil)
      @ref = ref
      @name = name
      @kind = kind
      @about = about.presence
    end

    # Is this one of the parties `refs` names? An empty list names everyone.
    def among?(refs)
      refs = Array(refs).map(&:to_s)
      refs.empty? || refs.include?(ref)
    end

    # What this someone is to her: their own entry, else the one for anyone.
    def relation(persona)
      relations = persona.relations
      relations[ref].presence || relations[ANYONE].presence
    end

    # The stage's text, or nil for a persona that keeps no relations: who is
    # there (what hob knows), then what they are to her (what she was given).
    def render(persona)
      return nil if persona.relations.empty?

      lines = [ "## Who you are talking to", "#{name}: #{DESCRIBED.fetch(kind, kind)}." ]
      lines << "What the person who brought them says about them: #{about}" if about
      lines << relation(persona).strip if relation(persona)
      lines.join("\n\n")
    end
  end
end
