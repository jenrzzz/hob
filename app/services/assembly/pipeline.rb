module Assembly
  # Composes every request's context as an ordered list of stages, each with a
  # token budget, and snapshots the result so any reply can answer "what
  # exactly did the model see?". Stage order is stable — persona first,
  # volatile context later — so provider prompt caching actually hits.
  class Pipeline
    DEFAULT_BUDGETS = { "history" => 8_000 }.freeze

    Result = Struct.new(:system, :messages, :snapshot, keyword_init: true)

    # head: the MessageNode the turn is being assembled at (usually the just-
    # appended user node, so the snapshot shows the full picture).
    def initialize(conversation:, head:, persona: nil, context: nil, budgets: {})
      @conversation = conversation
      @head = head
      @persona = persona
      @context = context
      @budgets = DEFAULT_BUDGETS.merge(budgets)
    end

    def assemble
      stages = [ persona_stage, scenario_stage, history_stage ].compact

      system = stages.filter_map { |s| s[:system] }.join("\n\n")
      messages = stages.flat_map { |s| s[:messages] || [] }

      snapshot = PromptSnapshot.record!(
        conversation: @conversation,
        assembled: {
          "stages" => stages.map { |s| s.except(:system, :messages).merge("tokens" => s[:tokens]) },
          "system" => system,
          "messages" => messages
        }
      )
      Result.new(system: system, messages: messages, snapshot: snapshot)
    end

    private

    def persona_stage
      return nil if @persona.nil? || @persona.system_core.blank?

      { "name" => "persona", "persona" => @persona.key,
        tokens: Assembly.estimate_tokens(@persona.system_core), system: @persona.system_core }
    end

    # The surface-context stage: whatever the host app says is "on screen",
    # rendered by the surface, budgeted and placed by hob.
    def scenario_stage
      return nil if @context.blank?

      rendered = @context.is_a?(String) ? @context : JSON.pretty_generate(@context)
      rendered = "## Context\n\n#{rendered}"
      { "name" => "scenario", tokens: Assembly.estimate_tokens(rendered), system: rendered }
    end

    # Newest-first fill within budget, then flipped chronological. Event nodes
    # stay in the DAG but out of the prompt.
    def history_stage
      budget = @budgets["history"]
      spent = 0
      kept = []

      @head.ancestry.each do |node|
        next unless %w[user assistant].include?(node.role)

        cost = Assembly.estimate_tokens(node.content)
        break if spent + cost > budget && kept.any?

        spent += cost
        kept << node
      end

      messages = kept.reverse.map do |node|
        content = node.speaker.present? ? "[#{node.speaker}]\n#{node.content}" : node.content
        { "role" => node.role, "content" => content, "hash" => node.content_hash }
      end
      { "name" => "history", "count" => messages.size, tokens: spent, messages: messages }
    end
  end
end
