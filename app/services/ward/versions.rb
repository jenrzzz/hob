module Ward
  # Version arithmetic for threats (THREATS.md): is what an asset runs at or
  # past the fixed version for its branch? Fixed versions are kept per
  # branch, { "8.3" => "8.3.36", "8.4" => "8.4.27" }, or as { "*" => "1.2.3" }
  # when there is one line. Anything ward cannot be sure of is "unknown",
  # never "fixed": a floating tag ("8.3"), a branch with no fix named, a
  # version that does not parse.
  #
  # A distro's own numbering is a scheme: Ubuntu's kernel 6.8.0-139 carries
  # fixes backported from upstream releases it does not name, so it is held
  # only to fixes named in its scheme, { "ubuntu:6.8.0" => "6.8.0-140" },
  # never to upstream's, and upstream's own numbers never see those.
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
    def verdict(version, fixed_versions, scheme: nil)
      fixed = in_scheme(fixed_versions, scheme)
      if fixed.empty?
        return [ "unknown", scheme.present? ? "no #{scheme} fixed version is known; upstream's do not apply" : "no fixed version is known" ]
      end

      running = parse(version)
      return [ "unknown", "the running version is not known" ] if running.nil?

      branch, fix = branch_for(running, fixed)
      if branch.nil?
        highest = fixed.values.filter_map { |v| parse(v) }.max
        # Upstream's later lines carry the fix; a distro names one per release it ships.
        return [ "fixed", "#{version} is a newer line than any with a fix named" ] if scheme.blank? && highest && newer_line?(running, highest)

        return [ "unknown", "no fixed version is named for #{version}'s line" ]
      end

      fix_version = parse(fix)
      return [ "unknown", "the fixed version #{fix.inspect} does not parse" ] if fix_version.nil?
      if numeric_segments(running).size < numeric_segments(fix_version).size
        return [ "unknown", "#{version} is a floating tag; the patch level is not known" ]
      end

      running >= fix_version ? [ "fixed", "#{version} ≥ #{fix}" ] : [ "vulnerable", "#{version} < #{fix}" ]
    end

    # The fixes that speak to a version in `scheme`, keyed by branch alone:
    # "ubuntu:6.8.0" for Ubuntu's, the unprefixed keys for upstream's.
    def in_scheme(fixed_versions, scheme)
      fixed = (fixed_versions || {}).transform_values(&:to_s).reject { |_, v| v.blank? }
      prefix = "#{scheme.to_s.strip.downcase}:"
      return fixed.reject { |branch, _| branch.include?(":") } if prefix == ":"

      fixed.filter_map { |branch, v| [ branch[prefix.size..], v ] if branch.downcase.start_with?(prefix) }.to_h
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
