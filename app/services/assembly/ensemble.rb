module Assembly
  # Splits one ensemble reply into speaker-attributed segments on [tag] lines
  # (B5). Untagged leading text belongs to the first speaker; unknown tags
  # stay in the running segment as ordinary text.
  module Ensemble
    module_function

    # -> [[speaker_key, text], ...] in reply order, blanks dropped.
    def split(content, keys)
      keys = Array(keys).map(&:to_s)
      if keys.size <= 1
        text = content.to_s.strip
        text = text.sub(/\A\[#{Regexp.escape(keys.first)}\]\s*/i, "") if keys.first
        return text.empty? ? [] : [ [ keys.first, text ] ]
      end

      pattern = /^\[(#{keys.map { |k| Regexp.escape(k) }.join('|')})\]\s*/i
      segments = []
      speaker = keys.first
      buffer = +""

      content.to_s.each_line do |line|
        if (match = line.match(pattern))
          segments << [ speaker, buffer ] if buffer.strip.present?
          speaker = keys.find { |k| k.casecmp?(match[1]) }
          buffer = +line.sub(pattern, "")
        else
          buffer << line
        end
      end
      segments << [ speaker, buffer ] if buffer.strip.present?
      segments.map { |s, t| [ s, t.strip ] }
    end
  end
end
