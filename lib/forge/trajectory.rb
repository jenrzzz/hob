require "json"
require "zlib"
require "stringio"

module Forge
  # What Claude Code did during a build: the session files it wrote
  # (~/.claude/projects/<the directory it ran in>/<session>.jsonl, and any
  # subagents' beside them), packed into one archive the loop hands to hob
  # with the mission (SENTINEL.md, "Trajectories").
  #
  # The archive is gzip over one JSON object:
  #
  #   { "format" => 1, "sessions" => [ { "session", "path", "lines", "jsonl" } ] }
  #
  # `path` is the file's place under its project directory, so a subagent's
  # file sits under its session's. Pure Ruby, as the rest of the forge: the
  # build packs, hob unpacks.
  module Trajectory
    FORMAT = 1
    MAX_SESSION = 24 * 1024 * 1024 # bytes of one session file kept whole
    HEAD = 400                     # lines kept from the start of a longer one
    TAIL = 1200                    # and from its end
    MAX_ARCHIVE = 24 * 1024 * 1024 # bytes, packed; past it the largest sessions go
    SECRET_ENV = %w[GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY HOB_AGENT_KEY HOB_KEY CODER_SESSION_TOKEN].freeze
    SECRETS_DIR = "/secrets".freeze
    SECRET_MIN = 12

    class Invalid < StandardError; end

    module_function

    # -> the archive's bytes, or nil when Claude Code wrote nothing under
    # `workdir` since `since`. Every secret this box can see is taken out of
    # what is kept: a session holds whatever a tool printed.
    def pack(workdir:, since:, home: nil, secrets: nil)
      secrets ||= self.secrets
      sessions = files(workdir, since, home || self.home).filter_map do |root, file|
        text = scrub(trim(File.binread(file)), secrets)
        next if text.strip.empty?

        path = file.delete_prefix("#{root}/")
        { "session" => path.split("/").first.delete_suffix(".jsonl"), "path" => path, "lines" => text.count("\n"), "jsonl" => text }
      end
      return nil if sessions.empty?

      loop do
        bytes = gzip(JSON.generate("format" => FORMAT, "sessions" => sessions))
        return bytes if bytes.bytesize <= MAX_ARCHIVE || sessions.size == 1

        sessions.delete(sessions.max_by { |s| s["jsonl"].bytesize })
      end
    end

    # -> the archive's sessions. Raises Invalid for anything that is not one.
    def unpack(bytes)
      data = JSON.parse(Zlib::GzipReader.new(StringIO.new(bytes.to_s.b)).read)
      raise Invalid, "not a trajectory archive (format #{data.is_a?(Hash) ? data['format'].inspect : 'unknown'})" unless data.is_a?(Hash) && data["format"] == FORMAT

      Array(data["sessions"]).select do |s|
        s.is_a?(Hash) && s["session"].is_a?(String) && s["path"].is_a?(String) && s["jsonl"].is_a?(String)
      end
    rescue Zlib::Error, JSON::ParserError => e
      raise Invalid, "not a trajectory archive: #{e.message}"
    end

    def gzip(text)
      out = StringIO.new("".b)
      writer = Zlib::GzipWriter.new(out)
      writer.write(text)
      writer.close
      out.string
    end

    # Claude Code names a project's directory for the directory it ran in,
    # every character that is not a letter or digit made a dash.
    def slug(path)
      path.to_s.gsub(/[^a-zA-Z0-9]/, "-")
    end

    def home
      ENV["CLAUDE_CONFIG_DIR"].to_s.empty? ? File.join(Dir.home, ".claude") : ENV["CLAUDE_CONFIG_DIR"]
    end

    # [project directory, session file] for every session written since
    # `since` by a run in `workdir` or below it, oldest first.
    def files(workdir, since, home)
      projects = File.join(home, "projects")
      workdir = File.expand_path(workdir)
      names = [ workdir, (File.realpath(workdir) rescue workdir) ].uniq.map { |dir| slug(dir) }
      found = names.flat_map do |name|
        Dir.glob(File.join(projects, "#{name}*")).select { |dir| File.directory?(dir) }.flat_map do |dir|
          Dir.glob(File.join(dir, "**", "*.jsonl")).map { |file| [ dir, file ] }
        end
      end
      found.uniq.select { |_, file| File.file?(file) && File.mtime(file) >= since - 1 }.sort_by { |_, file| File.mtime(file) }
    rescue SystemCallError
      []
    end

    # A session too long to keep whole keeps how it began and how it ended.
    def trim(text, limit: MAX_SESSION, head: HEAD, tail: TAIL)
      return text if text.bytesize <= limit

      lines = text.lines
      return text.byteslice(0, limit) if lines.size <= head + tail

      note = JSON.generate("type" => "forge-note", "note" => "#{lines.size - head - tail} lines left out here: the session was too long to keep whole")
      kept = (lines.first(head) + [ "#{note}\n" ] + lines.last(tail)).join
      kept.bytesize <= limit ? kept : kept.byteslice(0, limit)
    end

    def scrub(text, secrets)
      text = text.dup.force_encoding(Encoding::UTF_8).scrub("?")
      secrets.each { |value| text = text.gsub(value, "[secret]") }
      text
    end

    # Every secret here long enough to mean something: the tokens in the
    # environment and the files a workspace mounts.
    def secrets
      found = SECRET_ENV.map { |name| ENV[name].to_s.strip }
      Dir.glob(File.join(SECRETS_DIR, "*")).each do |file|
        found << File.read(file).strip if File.file?(file) && File.size(file) < 16_384
      rescue SystemCallError
        next
      end
      found.select { |value| value.length >= SECRET_MIN }.uniq
    end
  end
end
