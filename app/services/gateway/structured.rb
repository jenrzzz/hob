module Gateway
  # Structured-output hygiene, once, for every surface (A4): dig JSON out of
  # prose or code fences, and re-parse stringified JSON in top-level fields
  # (models sometimes hand back "[\"a\",\"b\"]" where an array was asked for).
  module Structured
    class ParseError < StandardError; end

    module_function

    def parse(text)
      text = text.to_s.strip
      raise ParseError, "empty reply" if text.empty?

      candidate = unfence(text)
      candidate = extract_json(candidate) || candidate
      repair(JSON.parse(candidate))
    rescue JSON::ParserError => e
      raise ParseError, e.message
    end

    def unfence(text)
      match = text.match(/\A```(?:json)?\s*(.*?)\s*```\z/m)
      match ? match[1] : text
    end

    # The outermost {...} or [...] in the text, if it isn't already all JSON.
    def extract_json(text)
      return text if text.start_with?("{", "[")

      open = text.index(/[{\[]/)
      return nil unless open

      close_char = text[open] == "{" ? "}" : "]"
      close = text.rindex(close_char)
      return nil unless close && close > open

      text[open..close]
    end

    def repair(value)
      case value
      when Hash
        value.transform_values { |v| repair(reparse_string(v)) }
      when Array
        value.map { |v| repair(reparse_string(v)) }
      else
        value
      end
    end

    def reparse_string(value)
      return value unless value.is_a?(String)

      stripped = value.strip
      return value unless (stripped.start_with?("{") && stripped.end_with?("}")) ||
                          (stripped.start_with?("[") && stripped.end_with?("]"))

      JSON.parse(stripped)
    rescue JSON::ParserError
      value
    end
  end
end
