module Assembly
  # Composes every request's context as an ordered list of stages, each with a
  # token budget, and snapshots the result so any reply can answer "what
  # exactly did the model see?". Stage order is stable — persona first,
  # volatile context later — so provider prompt caching actually hits.
  class Pipeline
    STAGE_DEFAULTS = [
      { "name" => "persona", "enabled" => true, "budget" => 2_000 },
      { "name" => "scenario", "enabled" => true, "budget" => 2_000 },
      { "name" => "history", "enabled" => true, "budget" => 8_000 }
    ].freeze

    Result = Struct.new(:system, :messages, :snapshot, keyword_init: true)

    # head: the MessageNode the turn is being assembled at (usually the just-
    # appended user node, so the snapshot shows the full picture).
    def initialize(conversation:, head:, persona: nil, context: nil, preset: nil)
      @conversation = conversation
      @head = head
      @persona = persona
      @context = context
      @preset = preset
      @stage_config = preset&.stage_config || STAGE_DEFAULTS
    end

    def assemble
      stages = @stage_config.filter_map do |config|
        next unless config["enabled"]

        build_stage(config)
      end

      system = stages.filter_map { |s| s[:system] }.join("\n\n")
      messages = stages.flat_map { |s| s[:messages] || [] }

      snapshot = PromptSnapshot.record!(
        conversation: @conversation,
        assembled: {
          "preset" => @preset&.key,
          "stages" => stages.map { |s| s.except(:system, :messages).merge("tokens" => s[:tokens]) },
          "system" => system,
          "messages" => messages
        }
      )
      Result.new(system: system, messages: messages, snapshot: snapshot)
    end

    private

    def build_stage(config)
      case config["name"]
      when "persona" then persona_stage
      when "scenario" then scenario_stage
      when "history" then history_stage(config["budget"] || 8_000)
      end
    end

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
    def history_stage(budget)
      spent = 0
      kept = []

      @head.ancestry.each do |node|
        next unless %w[user assistant].include?(node.role)

        cost = Assembly.estimate_tokens(node.content)
        break if spent + cost > budget && kept.any?

        spent += cost
        kept << node
      end

      # Speaker tags are the multi-persona ensemble convention; with a single
      # speaker they just teach the model to echo them back.
      tag_speakers = kept.filter_map(&:speaker).uniq.size > 1
      messages = kept.reverse.map do |node|
        content = node.content
        content = "[#{node.speaker}]\n#{content}" if tag_speakers && node.speaker.present?
        { "role" => node.role, "content" => content, "hash" => node.content_hash }
      end
      { "name" => "history", "count" => messages.size, tokens: spent, messages: messages }
    end
  end
end
