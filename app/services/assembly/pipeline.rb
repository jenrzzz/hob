module Assembly
  # Composes every request's context as an ordered list of stages, each with a
  # token budget, and snapshots the result so any reply can answer "what
  # exactly did the model see?". Stage order is stable — persona first,
  # volatile context later, the trailing instruction last — so provider
  # prompt caching actually hits.
  class Pipeline
    STAGE_DEFAULTS = [
      { "name" => "persona", "enabled" => true, "budget" => 2_000 },
      { "name" => "scenario", "enabled" => true, "budget" => 2_000 },
      { "name" => "history", "enabled" => true, "budget" => 8_000 },
      { "name" => "instruction", "enabled" => true, "budget" => 1_000 }
    ].freeze

    Result = Struct.new(:system, :messages, :snapshot, keyword_init: true)

    # head: the MessageNode the turn is being assembled at (the just-appended
    # user node, or the branch head for an assistant-initiated turn; nil on an
    # empty conversation).
    # personas: [] / [one] / [many] (an ensemble, B5)
    # context: String | Hash | [{ name, body, budget, volatile }] (B4)
    # instruction: trailing user-turn text; falls back to the persona's (B3)
    def initialize(conversation:, head:, personas: [], context: nil, instruction: nil, preset: nil)
      @conversation = conversation
      @head = head
      @personas = Array(personas).compact
      @context = context
      @instruction = instruction.presence || @personas.filter_map(&:instruction).first
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
          "stages" => stages.map { |s| s.except(:system, :messages, :tokens).merge("tokens" => s[:tokens]) },
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
      when "scenario" then scenario_stage(config["budget"])
      when "history" then history_stage(config["budget"] || 8_000)
      when "instruction" then instruction_stage
      end
    end

    def persona_stage
      voiced = @personas.select { |p| p.system_core.present? }
      return nil if voiced.empty?

      text = voiced.one? ? voiced.first.system_core : ensemble_text(voiced)
      { "name" => "persona", "persona" => voiced.map(&:key),
        tokens: Assembly.estimate_tokens(text), system: text }
    end

    # One model call voices several speakers; the reply is split on the tags.
    def ensemble_text(personas)
      header = <<~TEXT.strip
        You are voicing an ensemble of #{personas.size} speakers: #{personas.map { |p| "#{p.name} [#{p.key}]" }.join(', ')}.
        Begin each speaker's contribution with a line containing only their tag, for example [#{personas.first.key}].
        Not every speaker must speak every turn. Never speak for the user.
      TEXT
      [ header, *personas.map { |p| "## [#{p.key}] #{p.name}\n\n#{p.system_core}" } ].join("\n\n")
    end

    # The surface-context stage: whatever the host app says is "on screen",
    # rendered by the surface as named blocks, budgeted and placed by hob.
    # Stable blocks first in the given order, volatile ones last, so the
    # cacheable prefix is as long as possible.
    def scenario_stage(budget)
      blocks = context_blocks
      return nil if blocks.empty?

      ordered = blocks.reject { |b| b["volatile"] } + blocks.select { |b| b["volatile"] }
      spent = 0
      rendered = []
      kept = []
      ordered.each do |block|
        text, truncated = render_block(block)
        cost = Assembly.estimate_tokens(text)
        break if budget && spent + cost > budget && kept.any?

        spent += cost
        rendered << text
        kept << { "name" => block["name"], "tokens" => cost, "volatile" => !!block["volatile"], "truncated" => truncated }
      end

      body = blocks.one? && blocks.first["name"] == "context" ? rendered.first : rendered.join("\n\n")
      text = "## Context\n\n#{body}"
      { "name" => "scenario", "blocks" => kept, tokens: Assembly.estimate_tokens(text), system: text }
    end

    def context_blocks
      case @context
      when nil, "" then []
      when String then [ { "name" => "context", "body" => @context } ]
      when Array then @context.map { |b| b.to_h.stringify_keys }
      when Hash
        block = @context.to_h.stringify_keys
        block.key?("body") ? [ block ] : [ { "name" => "context", "body" => block } ]
      else
        raise ArgumentError, "context must be a string, a hash, or a list of blocks"
      end
    end

    # -> [text, truncated?]. A block's own budget clips its body.
    def render_block(block)
      body = block["body"]
      body = JSON.pretty_generate(body) unless body.is_a?(String)
      truncated = false
      if block["budget"] && Assembly.estimate_tokens(body) > block["budget"].to_i
        body = "#{body[0, block['budget'].to_i * 4]}\n[truncated]"
        truncated = true
      end
      text = block["name"] == "context" ? body : "### #{block['name']}\n\n#{body}"
      [ text, truncated ]
    end

    # Newest-first fill within budget, then flipped chronological. Event nodes
    # stay in the DAG but out of the prompt; tool calls and results are in
    # (the model needs to see what it asked for and what came back).
    def history_stage(budget)
      spent = 0
      kept = []

      (@head&.ancestry || []).each do |node|
        next unless %w[user assistant].include?(node.role)

        cost = Assembly.estimate_tokens(node.content)
        break if spent + cost > budget && kept.any?

        spent += cost
        kept << node
      end

      # Speaker tags are the multi-persona ensemble convention; with a single
      # speaker they just teach the model to echo them back.
      tag_speakers = @personas.size > 1 || kept.filter_map(&:speaker).uniq.size > 1
      messages = Transcript.render(kept.reverse, tag_speakers: tag_speakers)
      { "name" => "history", "count" => messages.size, tokens: spent, messages: messages }
    end

    # Post-history text as the final user turn: "ask the next question", "the
    # writer is stuck". This is what lets the assistant speak without a new
    # user node (B2/B3).
    def instruction_stage
      return nil if @instruction.blank?

      { "name" => "instruction", tokens: Assembly.estimate_tokens(@instruction),
        messages: [ { "role" => "user", "content" => @instruction } ] }
    end
  end
end
