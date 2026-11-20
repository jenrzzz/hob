module Assembly
  # A persona's sense of time (MELUZINA.md, "The clock"). Stored history is
  # content only, so an evening with hours of silence in it reads as one
  # breath and a week-old line reads as "just now". With `personas.clock`
  # set, the assembled copy of history carries drift markers where real gaps
  # opened, and a `clock` stage says what time it is now in each of her
  # zones, how long since the last visit, and which of her dates are near.
  #
  #   { "zones" => [{ "label", "zone", "reader"? }],   reader: whose hour drift markers name
  #     "drift_gap_minutes" => 20, "visit_gap_hours" => 6,
  #     "calendar" => [{ "month", "day", "label" }], "calendar_window_days" => 30 }
  #
  # Markers are computed from node timestamps, so they are the same on every
  # later turn and do not disturb the cached history prefix.
  class Clock
    DEFAULT_DRIFT_GAP = 20 # minutes
    DEFAULT_VISIT_GAP = 6  # hours
    DEFAULT_CALENDAR_WINDOW = 30 # days

    Zone = Struct.new(:label, :zone, :reader, keyword_init: true)

    def self.for(persona)
      config = persona&.clock
      config.present? ? new(config) : nil
    end

    def initialize(config)
      @config = config.to_h.deep_stringify_keys
      @zones = Array(@config["zones"]).map do |z|
        z = z.to_h.stringify_keys
        zone = z["zone"].to_s
        raise ArgumentError, "unknown time zone #{zone.inspect}" unless ActiveSupport::TimeZone[zone]

        Zone.new(label: z["label"].presence || zone, zone: zone, reader: z["reader"] ? true : false)
      end
      raise ArgumentError, "a clock needs at least one zone" if @zones.empty?

      @calendar = Array(@config["calendar"]).map do |entry|
        entry = entry.to_h.stringify_keys
        month, day = entry["month"].to_i, entry["day"].to_i
        raise ArgumentError, "calendar dates need a month and a day" unless Date.valid_date?(2024, month, day)

        { month: month, day: day, label: entry["label"].to_s }
      end
    end

    def drift_gap
      (@config["drift_gap_minutes"] || DEFAULT_DRIFT_GAP).to_i.minutes
    end

    def visit_gap
      (@config["visit_gap_hours"] || DEFAULT_VISIT_GAP).to_i.hours
    end

    # The zone whose hour matters for reading the person: the one marked
    # reader, else the first.
    def reader
      @zones.find(&:reader) || @zones.first
    end

    # Chronological nodes -> { content_hash => marker } for the spoken user
    # lines that arrive after a real gap. The gap is measured from the last
    # spoken line of either side; a whisper (an assistant line sent while he
    # was away) does not reset it, or a goodnight followed by a day of
    # whispers would read as him never having gone to bed.
    def drift_markers(nodes)
      markers = {}
      previous = nil
      nodes.each do |node|
        next unless spoken?(node)

        if previous && node.role == "user" && node.created_at - previous >= drift_gap
          markers[node.content_hash] = marker(previous, node.created_at)
        end
        previous = node.created_at unless whisper?(node)
      end
      markers
    end

    # The "now" block, or nil when there is nothing to say. head: the node
    # the turn is answering; the last visit is the newest spoken line before
    # the user's current one.
    def render(head:, now: Time.current)
      lines = @zones.map do |z|
        local = now.in_time_zone(z.zone)
        "- For #{z.label}: #{local.strftime('%A %B %-d, %-l:%M%P')}."
      end
      lines << last_visit_line(head, now) if head
      calendar_notes(now).each { |note| lines << "- Calendar: #{note}" }
      "## Right now\n\n(From hob's clock, not anyone's words.)\n\n#{lines.compact.join("\n")}"
    end

    def calendar_notes(now = Time.current)
      return [] if @calendar.empty?

      today = now.in_time_zone(reader.zone).to_date
      window = (@config["calendar_window_days"] || DEFAULT_CALENDAR_WINDOW).to_i
      @calendar.filter_map do |entry|
        date = next_occurrence(today, entry[:month], entry[:day])
        days = (date - today).to_i
        next if days > window

        days.zero? ? "today is #{entry[:label]}" : "in #{days} day#{'s' unless days == 1}: #{entry[:label]}"
      end
    end

    private

    def spoken?(node)
      %w[user assistant].include?(node.role) && node.kind == "text"
    end

    def whisper?(node)
      node.role == "assistant" && node.meta["whisper"]
    end

    # Absolute time on the reader's clock, so each stretch of the transcript
    # is anchored without arithmetic. The day name joins only when the
    # calendar rolled over between the two lines.
    def marker(previous, time)
      local = time.in_time_zone(reader.zone)
      clock = local.strftime("%-l:%M%P")
      if local.to_date == previous.in_time_zone(reader.zone).to_date
        "[time drifts — it's #{clock} for #{reader.label} now]"
      else
        "[time drifts — it's #{local.strftime('%A')} now, #{clock} for #{reader.label}]"
      end
    end

    def last_visit_line(head, now)
      chain = head.ancestry
      chain = chain.drop(1) if head.role == "user" && head.kind == "text" # the line being answered
      last = chain.find { |n| spoken?(n) && !whisper?(n) }
      return nil if last.nil? || now - last.created_at < visit_gap

      local = last.created_at.in_time_zone(reader.zone)
      days = (now.in_time_zone(reader.zone).to_date - local.to_date).to_i
      ago = case days
      when 0 then "earlier today"
      when 1 then "yesterday"
      else "#{days} days ago"
      end
      "- The last lines above were #{ago} (#{local.strftime('%B %-d')}). The conversation resumes across " \
        "that gap: whatever closed it is over, and this is a new #{days.zero? ? 'stretch' : 'day'}."
    end

    def next_occurrence(today, month, day)
      date = safe_date(today.year, month, day)
      date < today ? safe_date(today.year + 1, month, day) : date
    end

    # February 29 in a common year lands on the 28th.
    def safe_date(year, month, day)
      Date.valid_date?(year, month, day) ? Date.new(year, month, day) : Date.new(year, month, day - 1)
    end
  end
end
