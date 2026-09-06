# Two small hooks under the gateway transport (EXTRACTION.md A2). ruby_llm is
# a gem, not reloaded, so these prepend once at boot.
module HobRubyLLM
  # Keep each streamed event's raw JSON on the chunk. ruby_llm's chunks drop
  # everything but text and tokens, and the stop reason (refusal!) only
  # travels in Anthropic's message_delta / OpenAI's finish_reason.
  module RawChunks
    def handle_stream(&block)
      build_on_data_handler do |data|
        next unless data.is_a?(Hash)

        chunk = build_chunk(data)
        chunk.instance_variable_set(:@raw, data)
        block.call(chunk)
      end
    end
  end

  # Anthropic's SSE arrives gzipped with infrequent flushes; Ruby's inflater
  # then batches tokens into late bursts. Identity encoding streams cleanly.
  # (Lifted from parboil/kat; mirrors ruby_llm PR #771.)
  module IdentityEncoding
    def stream_response(connection, payload, additional_headers = {}, &block)
      super(connection, payload, additional_headers.merge("Accept-Encoding" => "identity"), &block)
    end
  end
end

RubyLLM::Provider.prepend(HobRubyLLM::RawChunks)
RubyLLM::Providers::Anthropic.prepend(HobRubyLLM::IdentityEncoding)
