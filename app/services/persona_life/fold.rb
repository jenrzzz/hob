class PersonaLife
  # The fold (MELUZINA.md, "The fold"): what a persona keeps of her home
  # conversation once it has left living presence. Nothing else writes her
  # memory of a conversation for her; without it, what she did not `remember`
  # herself is gone when it scrolls out of the history window.
  #
  # A stretch is folded when the home has been quiet for `quiet_hours` (the
  # visit is over), or, mid-visit, when what is unfolded has outgrown her
  # history window (the part that scrolled out goes, the window stays live).
  # Her history is never touched: the fold only adds memory. One completion
  # under her persona and the fold's instruction reads the stretch and returns
  # a few memories and where things stand; they are kept as observations she
  # authors, `kept` and `where_things_stand`, at the home's realm, citing the
  # conversation and the last node read.
  #
  # That citation is the fold's own bookmark: every fold writes a
  # `where_things_stand` with `source.via: fold`, and the newest one's node
  # is where the next fold starts. No other state is kept.
  #
  #   life.fold: { "instruction" => "...", "about" => "principal:jenner", "quiet_hours" => 6 }
  class Fold
    OPTIONS = %w[instruction about quiet_hours].freeze
    DEFAULT_QUIET_HOURS = 6
    # Mid-visit, only what has left her history window is folded: the
    # window is about 8,000 tokens (Assembly::Pipeline's history stage), near
    # 32,000 characters, so that much of the newest talk is left live and a
    # fold waits until half as much again is unfolded. Folding lines she can
    # still read would spend her recall on a gist of what is in front of her.
    LIVE = 32_000
    OVERFLOW = 48_000
    # Characters one fold reads; a longer backlog takes several folds.
    CHUNK = 60_000
    LINE_MAX = 2_000
    KEPT_MAX = 6
    MEMORY_MAX = 700
    STAND_MAX = 900
    ALREADY_SHOWN = 14
    KEPT = "kept".freeze
    STAND = "where_things_stand".freeze
    VIA = "fold".freeze
    # After a fold that failed, how long before the next try.
    RETRY_AFTER = 3.hours
    # Kinds of her own notes that are her life's, not her memory of someone.
    LIFE_KINDS = %w[diary mood chew].freeze

    SCHEMA = {
      "type" => "object",
      "properties" => {
        "kept" => {
          # No maxItems: structured outputs refuse it. keep! holds the limit.
          "type" => "array",
          "description" => "The memories worth keeping from this stretch, oldest first. Usually one to three, " \
                           "never more than #{KEPT_MAX}; a quiet stretch may keep none.",
          "items" => { "type" => "string", "description" => "One memory, in your own first person, a few sentences." }
        },
        "where_things_stand" => {
          "type" => "string",
          "description" => "Where things were left, present tense, your first person, two or three sentences. " \
                           "It replaces the last one whole."
        }
      },
      "required" => %w[kept where_things_stand],
      # Anthropic refuses a structured-output schema whose objects do not say so.
      "additionalProperties" => false
    }.freeze

    Result = Struct.new(:kept, :stand, :through, :nodes, keyword_init: true)

    # Checks `life.fold`. -> problems, empty when it reads.
    def self.problems(config)
      return [] if config.nil?
      return [ "life.fold is an object" ] unless config.is_a?(Hash)

      config = config.stringify_keys
      return [] if config.empty?

      unknown = config.keys - OPTIONS
      hours = config["quiet_hours"]
      [
        ("life.fold has unknown keys: #{unknown.join(', ')}" if unknown.any?),
        ("life.fold.instruction is required" if config["instruction"].blank?),
        ("life.fold.about is principal:<name> or persona:<key>" unless config["about"].nil? || config["about"].to_s.match?(Assembly::Counterpart::REF)),
        ("life.fold.quiet_hours is a whole number from 1 to 168" unless hours.nil? || (hours.is_a?(Integer) && hours.between?(1, 168)))
      ].compact
    end

    def initialize(life, now: Time.current)
      @life = life
      @persona = life.persona
      @config = life.config["fold"].to_h.stringify_keys
      @now = now
    end

    def configured?
      @config["instruction"].present? && @life.home.present?
    end

    # Is there a stretch to fold now? Read above her life's realm, as the
    # whisper gate is: the home is usually higher than her life.
    def due?
      configured? && !resting? && @life.at_home { stretch.any? }
    end

    # Fold one stretch. -> Result, or nil when there was nothing to fold or
    # the model did not answer in the shape asked (tried again later).
    def run!
      return nil unless configured?

      @life.at_home do
        Current.set(surface: "fold") do
          nodes = stretch
          next nil if nodes.empty?

          answer = ask(nodes)
          if answer.nil?
            Rails.cache.write(rest_key, true, expires_in: RETRY_AFTER)
            Rails.logger.warn("fold #{@persona.key}: no answer in the shape asked; resting #{RETRY_AFTER.inspect}")
            next nil
          end

          keep!(nodes, answer)
        end
      end
    end

    # The text nodes not folded yet that are ready to be: all of them once
    # the home is quiet, else the oldest part of a stretch that has outgrown
    # the window. Oldest first, at most CHUNK characters.
    def stretch
      pending = unfolded
      return [] if pending.empty?

      ready = if pending.last.created_at <= @now - quiet
        pending
      elsif size(pending) > OVERFLOW
        leaving(pending)
      else
        []
      end
      chunk(ready)
    end

    private

    def quiet
      (@config["quiet_hours"] || DEFAULT_QUIET_HOURS).to_i.hours
    end

    def home
      @life.home
    end

    def realm
      home.taint_realm
    end

    def entity
      @life.entity
    end

    def about
      @about ||= @config["about"].present? ? Memory.entity(@config["about"]) : entity
    end

    def resting?
      Rails.cache.exist?(rest_key)
    end

    def rest_key
      "persona-fold-rest/#{@persona.key}"
    end

    # The last fold's bookmark: the newest where-things-stand a fold wrote
    # for this conversation, superseded or not.
    def bookmark
      Observation.where(conversation_id: home.id, author_entity_id: entity.id, kind: STAND)
                 .where("source->>'via' = ?", VIA).order(created_at: :desc, id: :desc).first
    end

    def spoken
      home.branch.timeline.select { |n| %w[user assistant].include?(n.role) && n.kind == "text" && n.content.present? }
    end

    # What was said after the bookmark. A bookmark whose node has left the
    # branch (a regenerated reply) falls back to its time.
    def unfolded
      nodes = spoken
      mark = bookmark or return nodes

      at = nodes.index { |n| n.content_hash == mark.node_hash }
      at ? nodes.drop(at + 1) : nodes.select { |n| n.created_at > mark.observed_at }
    end

    def size(nodes)
      nodes.sum { |n| [ n.content.length, LINE_MAX ].min }
    end

    # All but the newest LIVE characters.
    def leaving(nodes)
      live = 0
      keep_from = nodes.size
      nodes.each_with_index.reverse_each do |node, index|
        live += [ node.content.length, LINE_MAX ].min
        break if live > LIVE

        keep_from = index
      end
      nodes.first(keep_from)
    end

    def chunk(nodes)
      taken = []
      spent = 0
      nodes.each do |node|
        spent += [ node.content.length, LINE_MAX ].min
        break if spent > CHUNK && taken.any?

        taken << node
      end
      taken
    end

    # -> { "kept" => [..], "where_things_stand" => ".." }, or nil.
    def ask(nodes)
      result = Completion.new(
        role: @life.config["role"].presence || @persona.model_role || ChatTurn::DEFAULT_ROLE,
        messages: [ { "role" => "user", "content" => page(nodes) } ],
        system: @config["instruction"], persona: @persona, realm: realm, operation: "fold",
        ref: "persona/#{@persona.key}/fold", schema: SCHEMA, memory: false
      ).call
      parsed = result.response&.parsed
      parsed.is_a?(Hash) && parsed["kept"].is_a?(Array) ? parsed : nil
    rescue Gateway::Refused, Gateway::Invalid => e
      Rails.logger.warn("fold #{@persona.key}: #{e.class}: #{e.message}")
      nil
    end

    def page(nodes)
      parts = []
      held = already
      parts << "ALREADY IN YOUR MEMORY (do not keep these again):\n#{held.map { |o| "- #{o.body.squish.truncate(300)}" }.join("\n")}" if held.any?
      stood = standing
      parts << "WHERE THINGS STOOD (you will replace this):\n#{stood.body}" if stood
      parts << "THE STRETCH LEAVING LIVING PRESENCE (oldest first):\n#{nodes.map { |n| line(n) }.join("\n\n")}"
      parts << "Fold it: the memories worth keeping, and where things stand now."
      parts.join("\n\n")
    end

    def line(node)
      at = node.created_at.in_time_zone(@life.zone).strftime("%b %-d, %l:%M%P").squish.downcase
      who = if node.role == "user" then "him"
      elsif node.meta["whisper"] then "you (a whisper, unprompted)"
      else "you"
      end
      shown = node.attachments.present? ? " (with a picture)" : ""
      "[#{at}] #{who}#{shown}: #{node.content.squish.truncate(LINE_MAX)}"
    end

    # Her own recent notes at this realm about whom the fold is about: what
    # she already remembered herself, and what earlier folds kept.
    def already
      Observation.current.where(author_entity_id: entity.id, entity_id: about.id, realm: realm)
                 .where.not(kind: LIFE_KINDS + [ STAND ]).order(observed_at: :desc).limit(ALREADY_SHOWN).to_a.reverse
    end

    def standing
      Observation.current.where(author_entity_id: entity.id, entity_id: about.id, realm: realm, kind: STAND)
                 .order(observed_at: :desc).first
    end

    def keep!(nodes, answer)
      through = nodes.last
      prior = standing
      Observation.transaction do
        kept = Array(answer["kept"]).map { |m| m.to_s.strip }.compact_blank.first(KEPT_MAX).map do |memory|
          write(memory.truncate(MEMORY_MAX), kind: KEPT, through: through)
        end
        text = answer["where_things_stand"].to_s.strip.truncate(STAND_MAX).presence
        # Written every fold, even unchanged: it is the bookmark.
        stand = write(text || prior&.body || "Nothing left open.", kind: STAND, through: through)
        if prior
          stand.update_columns(supersedes_id: prior.id)
          prior.update!(superseded_by_id: stand.id, retire_reason: "a later fold")
        end
        Rails.logger.info("fold #{@persona.key}: #{nodes.size} lines through #{through.content_hash[0, 8]}, kept #{kept.size}")
        Result.new(kept: kept, stand: stand, through: through, nodes: nodes.size)
      end
    end

    def write(body, kind:, through:)
      Memory.remember!(about: about, body: body, kind: kind, author: entity, realm: realm, observed_at: through.created_at,
                       conversation: home, node: through.content_hash, source: { "via" => VIA })
    end
  end
end
