module Ward
  # Version arithmetic for threats (THREATS.md): is what an asset runs at or
  # past the fixed version for its branch? Fixed versions are kept per
  # branch, { "8.3" => "8.3.36", "8.4" => "8.4.27" }, or as { "*" => "1.2.3" }
  # when there is one line. Anything ward cannot be sure of is "unknown",
  # never "fixed": a floating tag ("8.3"), a branch with no fix named, a
  # version that does not parse.
  module Versions
    VERDICTS = %w[vulnerable fixed unknown].freeze
    # "v8.3.30-fpm" → "8.3.30"; "4.0.0-beta.420" and "8.4.0RC1-fpm" keep
    # their prerelease; "latest" → nil.
    LEADING = /\A[vV]?(\d+(?:\.\d+)+(?:[-.]?(?:alpha|beta|rc|pre)(?:[.-]?\d+)*)?)/i

    module_function

    def parse(text)
      text = text.to_s.strip.delete_prefix("v").delete_prefix("V")
      Gem::Version.new(text) if text.present? && Gem::Version.correct?(text)
    end

    # The version a tag names, if it names one.
    def from_tag(tag)
      tag.to_s[LEADING, 1]
    end

    def numeric_segments(version)
      version.segments.take_while { |s| s.is_a?(Integer) }
    end

    # -> [verdict, why]
    def verdict(version, fixed_versions)
      fixed = (fixed_versions || {}).transform_values(&:to_s).reject { |_, v| v.blank? }
      return [ "unknown", "no fixed version is known" ] if fixed.empty?

      running = parse(version)
      return [ "unknown", "the running version is not known" ] if running.nil?

      branch, fix = branch_for(running, fixed)
      if branch.nil?
        highest = fixed.values.filter_map { |v| parse(v) }.max
        return [ "fixed", "#{version} is a newer line than any with a fix named" ] if highest && newer_line?(running, highest)

        return [ "unknown", "no fixed version is named for #{version}'s line" ]
      end

      fix_version = parse(fix)
      return [ "unknown", "the fixed version #{fix.inspect} does not parse" ] if fix_version.nil?
      if numeric_segments(running).size < numeric_segments(fix_version).size
        return [ "unknown", "#{version} is a floating tag; the patch level is not known" ]
      end

      running >= fix_version ? [ "fixed", "#{version} ≥ #{fix}" ] : [ "vulnerable", "#{version} < #{fix}" ]
    end

    # The longest branch key the version falls under: "8.3" holds 8.3.30;
    # "*" holds everything.
    def branch_for(running, fixed)
      numbers = numeric_segments(running)
      fixed.select { |branch, _| branch == "*" || branch_prefix?(branch, numbers) }
           .max_by { |branch, _| branch == "*" ? -1 : branch.count(".") }
    end

    def branch_prefix?(branch, numbers)
      prefix = branch.split(".").map { |s| Integer(s, exception: false) }
      prefix.none?(&:nil?) && numbers.first(prefix.size) == prefix
    end

    # 8.5.0 against fixes for 8.3 and 8.4: a later major.minor than any fixed.
    def newer_line?(running, highest)
      (numeric_segments(running).first(2) <=> numeric_segments(highest).first(2)) == 1
    end
  end
end
