# What Claude Code did on a mission (SENTINEL.md, "Trajectories"): keeping
# the session files the forge hands over, and reading one back as the steps
# a person follows: what it was told, what it said, each tool it called and
# what came back.
module Trajectories
  MAX_ARCHIVE = 32 * 1024 * 1024 # bytes, as handed over
  MAX_SESSIONS = 200
  CLIP = 6_000                   # characters of any one text a page shows

  # One thing that happened. kind: :prompt (said to it), :text (it said),
  # :thinking, :tool (a call and, once it arrived, its result), :note.
  Step = Struct.new(:kind, :at, :text, :name, :input, :result, :failed, :side, keyword_init: true)

  module_function

  # Keeps an archive's sessions beside `mission`, at its realm. A session
  # file handed over twice replaces itself. -> the rows
  def store!(mission, archive)
    raise Gateway::Invalid, "the archive is empty" if archive.blank?
    raise Gateway::Invalid, "the archive is #{archive.bytesize} bytes; the limit is #{MAX_ARCHIVE}" if archive.bytesize > MAX_ARCHIVE

    sessions = Forge::Trajectory.unpack(archive)
    raise Gateway::Invalid, "the archive holds no sessions" if sessions.empty?
    raise Gateway::Invalid, "the archive holds #{sessions.size} sessions; the limit is #{MAX_SESSIONS}" if sessions.size > MAX_SESSIONS

    MissionTrajectory.transaction do
      sessions.map do |session|
        text = session["jsonl"].dup.force_encoding(Encoding::UTF_8).scrub("?").delete("\u0000")
        row = MissionTrajectory.find_or_initialize_by(mission_id: mission.id, path: session["path"].first(500))
        row.update!(realm: mission.realm, attempt: mission.attempts, session: session["session"].first(100),
                    lines: text.count("\n"), bytes: text.bytesize, body: Forge::Trajectory.gzip(text),
                    created_at: row.created_at || Time.current)
        row
      end
    end
  rescue Forge::Trajectory::Invalid => e
    raise Gateway::Invalid, e.message
  end

  # -> [steps, skipped]: the session as Steps in the order they happened,
  # each tool call carrying its result, and how many lines were bookkeeping
  # (snapshots, modes, request records) or unreadable.
  def steps(jsonl)
    steps = []
    calls = {}
    skipped = 0
    jsonl.each_line do |line|
      entry = begin
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      unless entry.is_a?(Hash)
        skipped += 1
        next
      end

      at = entry["timestamp"]
      side = entry["isSidechain"] == true
      content = entry.dig("message", "content")
      case entry["type"]
      when "user"
        if content.is_a?(String)
          steps << Step.new(kind: :prompt, at: at, text: content, side: side)
        else
          Array(content).each do |block|
            next unless block.is_a?(Hash)

            if block["type"] == "tool_result"
              call = calls[block["tool_use_id"]]
              text = flatten(block["content"])
              if call
                call.result = text
                call.failed = block["is_error"] == true
              else
                steps << Step.new(kind: :note, at: at, text: text, name: "a tool result with no call", side: side)
              end
            elsif block["type"] == "text"
              steps << Step.new(kind: :prompt, at: at, text: block["text"].to_s, side: side)
            end
          end
        end
      when "assistant"
        Array(content).each do |block|
          next unless block.is_a?(Hash)

          case block["type"]
          when "text" then steps << Step.new(kind: :text, at: at, text: block["text"].to_s, side: side) if block["text"].present?
          when "thinking" then steps << Step.new(kind: :thinking, at: at, text: block["thinking"].to_s, side: side) if block["thinking"].present?
          when "tool_use"
            step = Step.new(kind: :tool, at: at, name: block["name"].to_s, input: block["input"], side: side)
            calls[block["id"]] = step
            steps << step
          end
        end
      when "system"
        text = entry["content"].presence || entry["subtype"].to_s
        steps << Step.new(kind: :note, at: at, text: text.to_s, name: entry["subtype"].presence || "system", side: side)
      when "forge-note"
        steps << Step.new(kind: :note, at: at, text: entry["note"].to_s, name: "forge")
      else
        skipped += 1
      end
    end
    [ steps, skipped ]
  end

  # A tool result's content: a string, or blocks of text and images.
  def flatten(content)
    return content.to_s unless content.is_a?(Array)

    content.map do |block|
      next block.to_s unless block.is_a?(Hash)

      block["type"] == "text" ? block["text"].to_s : "[#{block['type']}]"
    end.join("\n")
  end

  # What a tool call was about, in a line: the command, the file, the pattern.
  def headline(step)
    input = step.input.is_a?(Hash) ? step.input : {}
    line = %w[command file_path path pattern url query description prompt skill].filter_map { |key| input[key].presence }.first
    line = input.to_json if line.nil? && input.any?
    line.to_s.gsub(/\s+/, " ").strip.truncate(160)
  end

  # -> [what a page shows of `text`, how many characters it left out]
  def clip(text, limit = CLIP)
    text = text.to_s
    text.length > limit ? [ text.first(limit), text.length - limit ] : [ text, 0 ]
  end
end
