class UsageEvent < ApplicationRecord
  # Everything the admin Usage page shows, computed from request params.
  # Ported from kat's LLMUsage::Report.
  #
  # Two scopes matter:
  #   chart_scope      the period, with every filter applied except the
  #                    dimension the chart is colored by, so picking a series
  #                    dims its siblings instead of erasing them.
  #   selection_scope  chart_scope narrowed to the picked bucket (from/to) and
  #                    series; the stats, breakdowns and call list read this.
  class Report
    PERIODS = { "today" => "Today", "7d" => "7 days", "30d" => "30 days", "90d" => "90 days", "all" => "All time" }.freeze
    DEFAULT_PERIOD = "7d"

    GROUPS = { "role" => "Role", "operation" => "Operation", "model" => "Model", "surface" => "Surface" }.freeze
    DEFAULT_GROUP = "operation"

    METRICS = { "cost" => "Cost", "calls" => "Calls" }.freeze
    DEFAULT_METRIC = "cost"

    STATUSES = { "success" => "Success", "refused" => "Refused", "empty" => "Empty reply",
                 "failed" => "Failed (error or rate limit)",
                 "error" => "Error", "rate_limited" => "Rate limited" }.freeze

    FILTER_DIMS = %i[role operation model surface provider principal_id status tool ref].freeze

    # Eight validated categorical slots; past that the rest fold into "Other".
    MAX_SERIES = 8
    NONE = "none" # filter value for "column was blank"
    OTHER = "other"

    Series = Data.define(:key, :name, :slot)
    Bucket = Data.define(:starts_at, :ends_at, :values, :calls)

    attr_reader :period, :group, :metric, :params

    def initialize(params)
      @params = params.to_h.with_indifferent_access
      @period = PERIODS.key?(@params[:period]) ? @params[:period] : DEFAULT_PERIOD
      @group = GROUPS.key?(@params[:group]) ? @params[:group] : DEFAULT_GROUP
      @metric = METRICS.key?(@params[:metric]) ? @params[:metric] : DEFAULT_METRIC
    end

    # --- Window ---------------------------------------------------------

    def range_start
      @range_start ||= case period
      when "today" then Time.current.beginning_of_day
      when "7d" then 6.days.ago.beginning_of_day
      when "30d" then 29.days.ago.beginning_of_day
      when "90d" then 89.days.ago.beginning_of_day
      else (UsageEvent.minimum(:created_at) || Time.current).beginning_of_day
      end
    end

    def range_end
      @range_end ||= Time.current
    end

    def unit
      @unit ||= begin
        days = (range_end - range_start) / 1.day
        if days <= 2 then "hour"
        elsif days <= 120 then "day"
        else "week"
        end
      end
    end

    # --- Filters --------------------------------------------------------

    def selected_from = parse_time(params[:from])
    def selected_to = parse_time(params[:to])
    def bucket_selected? = selected_from.present? && selected_to.present?
    def filter_value(dim) = params[dim].presence
    def filtered? = FILTER_DIMS.any? { |d| filter_value(d) } || bucket_selected?

    def base_scope
      UsageEvent.where(created_at: range_start..range_end)
    end

    def chart_scope
      @chart_scope ||= apply_filters(base_scope, except: group.to_sym)
    end

    def selection_scope
      @selection_scope ||= begin
        scope = apply_filters(base_scope)
        scope = scope.where(created_at: selected_from...selected_to) if bucket_selected?
        scope
      end
    end

    # --- Chart ----------------------------------------------------------

    def series
      @series ||= begin
        ranked = chart_scope.group(Arel.sql(group_sql)).order(Arel.sql("#{measure_sql} DESC"))
                            .limit(MAX_SERIES + 1).pluck(Arel.sql(group_sql))
        keys = ranked.map { |k| k.presence || NONE }
        list = keys.first(MAX_SERIES).each_with_index.map { |k, i| Series.new(key: k, name: series_name(k), slot: i + 1) }
        list << Series.new(key: OTHER, name: "Other", slot: 0) if keys.size > MAX_SERIES
        list
      end
    end

    def buckets
      @buckets ||= begin
        trunc = "date_trunc('#{unit}', (usage_events.created_at AT TIME ZONE 'UTC') AT TIME ZONE #{quoted_zone})"
        rows = chart_scope.group(Arel.sql(trunc), Arel.sql(group_sql))
                          .pluck(Arel.sql(trunc), Arel.sql(group_sql), Arel.sql(measure_sql), Arel.sql("COUNT(*)"))
        known = series.map(&:key).to_set
        by_start = Hash.new { |h, k| h[k] = { values: Hash.new(0.0), calls: 0 } }
        rows.each do |local_start, key, value, calls|
          key = key.presence || NONE
          key = OTHER unless known.include?(key)
          slot = by_start[Time.zone.local_to_utc(local_start).to_i]
          slot[:values][key] += value.to_f
          slot[:calls] += calls
        end
        bucket_starts.map do |start|
          data = by_start[start.to_i]
          Bucket.new(starts_at: start, ends_at: start + step, values: data[:values], calls: data[:calls])
        end
      end
    end

    def series_totals
      @series_totals ||= buckets.each_with_object(Hash.new(0.0)) { |b, h| b.values.each { |k, v| h[k] += v } }
    end

    # --- Selection ------------------------------------------------------

    def stats
      @stats ||= begin
        calls, refused, empty, failed, cost, input, output, cache_read, avg, unpriced = selection_scope.pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'refused')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'empty')"),
          Arel.sql("COUNT(*) FILTER (WHERE status IN ('error', 'rate_limited'))"),
          Arel.sql("COALESCE(SUM(cost), 0)"),
          Arel.sql("COALESCE(SUM((units->>'input_tokens')::bigint), 0)"),
          Arel.sql("COALESCE(SUM((units->>'output_tokens')::bigint), 0)"),
          Arel.sql("COALESCE(SUM((units->>'cache_read_tokens')::bigint), 0)"),
          Arel.sql("AVG(duration_ms) FILTER (WHERE status = 'success')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'success' AND cost IS NULL)")
        )
        { calls: calls, refused: refused, empty: empty, failed: failed, cost: cost.to_f, input_tokens: input, output_tokens: output,
          cache_read_tokens: cache_read, avg_duration_ms: avg&.round, unpriced: unpriced }
      end
    end

    def by_role = breakdown("usage_events.role", limit: 10)
    def by_operation = breakdown("usage_events.operation", limit: 12)
    def by_model = breakdown("usage_events.model", limit: 8)
    def by_surface = breakdown("usage_events.surface", limit: 10)

    def by_principal
      rows = breakdown("usage_events.principal_id", limit: 10)
      names = Principal.where(id: rows.map { |r| r[:key] }.compact).pluck(:id, :name).to_h
      rows.each { |r| r[:name] = r[:key] ? names[r[:key]] || "##{r[:key]}" : "Unattributed" }
    end

    # Tools the model asked for: one row per name, counted per call.
    def by_tool(limit: 12)
      selection_scope.where("cardinality(tool_names) > 0")
                     .joins("CROSS JOIN LATERAL unnest(usage_events.tool_names) AS tool(name)")
                     .group("tool.name").order(Arel.sql("COUNT(*) DESC")).limit(limit)
                     .pluck(Arel.sql("tool.name"), Arel.sql("COUNT(*)"))
                     .map { |name, calls| { key: name, calls: calls } }
    end

    def calls
      selection_scope.includes(:principal).recent
    end

    # --- Labels ---------------------------------------------------------

    def series_name(key)
      return "Other" if key == OTHER
      return "(none)" if key == NONE

      key
    end

    def selection_label
      parts = []
      parts << bucket_label(selected_from, long: true) if bucket_selected?
      FILTER_DIMS.each do |dim|
        value = filter_value(dim)
        next unless value

        parts << case dim
        when :status then STATUSES.fetch(value, value)
        when :principal_id then value == NONE ? "no principal" : (Principal.find_by(id: value)&.name || "principal ##{value}")
        when :tool then "called #{value}"
        when :ref then value
        else value == NONE ? "no #{dim}" : value
        end
      end
      parts.presence&.join(" · ")
    end

    def bucket_label(time, long: false)
      return "" unless time

      case unit
      when "hour" then long ? time.strftime("%b %-d, %-l %p") : time.strftime("%-l%P")
      when "week" then long ? "week of #{time.strftime('%b %-d, %Y')}" : time.strftime("%b %-d")
      else long ? time.strftime("%a %b %-d, %Y") : time.strftime("%b %-d")
      end
    end

    # Params for links that keep the current view and change one thing.
    def link_params(overrides = {})
      base = params.slice(:period, :group, :metric, :from, :to, *FILTER_DIMS).compact_blank
      base.merge(overrides.stringify_keys).compact_blank.symbolize_keys
    end

    private

    def apply_filters(scope, except: nil)
      FILTER_DIMS.each do |dim|
        next if dim == except

        value = filter_value(dim)
        next unless value

        scope = case dim
        when :status then value == "failed" ? scope.failed : scope.where(status: value)
        when :tool then scope.where("? = ANY(usage_events.tool_names)", value)
        when :principal_id then scope.where(principal_id: value == NONE ? nil : value.to_i)
        else scope.where(dim => value == NONE ? [ nil, "" ] : value)
        end
      end
      scope
    end

    def group_sql
      "usage_events.#{group}"
    end

    def measure_sql
      metric == "calls" ? "COUNT(*)" : "COALESCE(SUM(cost), 0)"
    end

    def breakdown(column_sql, limit: nil)
      rel = selection_scope.group(Arel.sql(column_sql))
                           .order(Arel.sql("COALESCE(SUM(cost), 0) DESC, COUNT(*) DESC"))
      rel = rel.limit(limit) if limit
      rel.pluck(
        Arel.sql(column_sql),
        Arel.sql("COALESCE(SUM(cost), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'refused')"),
        Arel.sql("COUNT(*) FILTER (WHERE status IN ('error', 'rate_limited'))"),
        Arel.sql("COALESCE(SUM(COALESCE((units->>'input_tokens')::bigint, 0) + COALESCE((units->>'output_tokens')::bigint, 0)), 0)"),
        Arel.sql("AVG(duration_ms)")
      ).map do |key, cost, calls, refused, failed, tokens, avg|
        { key: key.presence, cost: cost.to_f, calls: calls, refused: refused, failed: failed, tokens: tokens,
          avg_duration_ms: avg&.round }
      end
    end

    def step
      { "hour" => 1.hour, "day" => 1.day, "week" => 1.week }.fetch(unit)
    end

    def bucket_starts
      t = case unit
      when "hour" then range_start.beginning_of_hour
      when "week" then range_start.beginning_of_week(:monday)
      else range_start.beginning_of_day
      end
      starts = []
      while t <= range_end
        starts << t
        t += step
      end
      starts
    end

    def quoted_zone
      ActiveRecord::Base.connection.quote(Time.zone.tzinfo.name)
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
