# One small hook under the gateway transport (EXTRACTION.md A2). ruby_llm is
# a gem, not reloaded, so this prepends once at boot.
module HobRubyLLM
  # Keep each streamed event's raw JSON on the chunk. ruby_llm reads the stop
  # reason off the stream itself now, but normalizes it (end_turn -> :stop,
  # refusal -> :content_filter); hob's callers and ledger are promised the
  # provider's own word, which only travels in Anthropic's message_delta /
  # OpenAI's finish_reason.
  module RawChunks
    def build_chunk(data)
      super.tap { |chunk| chunk.instance_variable_set(:@raw, data) }
    end
  end
end

# The two wire protocols Gateway::Transport speaks. build_chunk comes from a
# module each includes, so the prepend has to sit on the class.
[ RubyLLM::Protocols::Anthropic, RubyLLM::Protocols::ChatCompletions ].each { |protocol| protocol.prepend(HobRubyLLM::RawChunks) }
