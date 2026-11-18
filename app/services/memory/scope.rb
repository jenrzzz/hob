module Memory
  # Whose memory a turn uses and how (MEMORY.md, "In a turn"): the persona
  # whose memory it is, who the turn is about, whether the recall stage runs,
  # whether the native tools are offered, and the budget.
  #
  # Off unless the persona's `memory` defaults or the request's `memory:` turn
  # it on. `memory: true` is { recall: true, tools: true }; `memory: false`
  # turns it off whatever the persona says.
  #
  # Realms inside a conversation:
  # - reads run at min(request clearance, conversation realm), because what
  #   is read lands in that conversation's nodes and snapshots, which anyone
  #   cleared for the conversation can read;
  # - writes land at the conversation's taint, capped by the request's
  #   clearance: what the model knew when it decided to remember.
  class Scope
    OPTIONS = %w[recall tools budget about].freeze
    DEFAULT_BUDGET = 600 # tokens

    attr_reader :persona, :conversation, :about

    # -> a Scope, or nil when memory is off for this turn.
    def self.build(personas:, conversation:, request: nil)
      return nil if request == false

      options = case request
      when nil then {}
      when true then { "recall" => true, "tools" => true }
      when Hash, ActionController::Parameters then request.to_h.stringify_keys
      else raise Gateway::Invalid, "memory is true, false, or { recall, tools, budget, about }"
      end
      unknown = options.keys - OPTIONS
      raise Gateway::Invalid, "unknown memory option: #{unknown.join(', ')}" if unknown.any?

      personas = Array(personas).compact
      merged = (personas.first&.memory_options || {}).merge(options)
      return nil unless merged["recall"] || merged["tools"]
      raise Gateway::Invalid, "memory needs exactly one persona (the one whose memory it is)" unless personas.one?

      new(persona: personas.first, conversation: conversation, options: merged)
    end

    def initialize(persona:, conversation:, options:)
      @persona = persona
      @conversation = conversation
      @options = options
      @about = resolve_about(options["about"])
    end

    def recall?
      !!@options["recall"]
    end

    def tools?
      !!@options["tools"]
    end

    def budget_tokens
      (@options["budget"] || DEFAULT_BUDGET).to_i.clamp(50, 8_000)
    end

    def author
      @author ||= persona.memory_entity
    end

    # The realm this conversation's memory is read at.
    def read_realm
      [ Clearance.current, conversation.realm ].compact.min_by { |r| Realm.rank_of(r) }
    end

    # The realm a `remember` in this conversation lands at.
    def write_realm
      [ conversation.taint_realm, Clearance.current ].compact.min_by { |r| Realm.rank_of(r) }
    end

    def read
      Clearance.with(read_realm) { yield }
    end

    def config
      @options.slice(*OPTIONS)
    end

    private

    # Who the turn is about: the request's `about`, else the person whose key
    # it is. A surface or worker key is about nobody in particular.
    def resolve_about(about)
      refs = Array(about).compact_blank
      return refs.map { |ref| Memory.entity(ref) } if refs.any?
      return [ Entity.for_principal(Current.principal) ] if Current.principal&.trusted?

      []
    end
  end
end
