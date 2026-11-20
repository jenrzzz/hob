# Formatting for the admin Usage pages.
module UsageHelper
  def usage_money(amount, precise: false)
    return tag.span("unpriced", class: "muted") if amount.nil?

    n = amount.to_f
    return "$0" if n.zero?
    return format("$%.6f", n) if precise
    return "<$0.01" if n < 0.01

    number_to_currency(n, precision: n < 10 ? 2 : 0)
  end

  def usage_tokens(count)
    n = count.to_i
    if n >= 1_000_000 then "#{(n / 1_000_000.0).round(1)}M"
    elsif n >= 10_000 then "#{(n / 1000.0).round}k"
    elsif n >= 1000 then "#{(n / 1000.0).round(1)}k"
    else n.to_s
    end
  end

  def usage_duration(ms)
    return "–" if ms.nil?

    ms < 1000 ? "#{ms}ms" : "#{(ms / 1000.0).round(1)}s"
  end

  def usage_metric(value, metric)
    metric == "calls" ? number_with_delimiter(value.to_i) : usage_money(value)
  end

  def usage_swatch(slot)
    tag.span(class: "swatch", style: "background: var(--s#{slot})", "aria-hidden": true)
  end

  def usage_status(event)
    tag.span(event.status.tr("_", " "), class: [ "status", event.status ])
  end

  # A round axis top for `max` and its tick values (0 excluded).
  def usage_axis(max)
    return [ 1, [] ] unless max.to_f.positive?

    magnitude = 10**Math.log10(max).floor
    top = [ 1, 2, 2.5, 5, 10 ].map { |m| m * magnitude }.find { |v| v >= max }
    [ top, [ top / 2.0, top ] ]
  end
end
