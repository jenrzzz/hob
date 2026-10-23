# Something the household runs, as the ward knows it (THREATS.md): a host,
# Coolify itself, an application, service, or database Coolify manages, or
# an address ward scans. `components` is what the inventory implies (an
# image's name and tag, a known stack); `declared` is what a person said
# and wins over it. A threat is matched against these.
class WardAsset < ApplicationRecord
  KINDS = %w[host control_plane application service database target].freeze
  SOURCES = %w[coolify scan_target person].freeze
  EXPOSURES = %w[public tailnet localhost].freeze
  # public outranks tailnet outranks localhost when ward weighs a threat.
  EXPOSURE_RANK = { "public" => 0, "tailnet" => 1, "localhost" => 2 }.freeze

  # One spelling for a component everywhere it is written or matched:
  # lowercase, hyphens and spaces as underscores, which is how NVD's CPE
  # products are named ("oauth2-proxy" → "oauth2_proxy").
  def self.component_name(name)
    name.to_s.strip.downcase.gsub(/[\s-]+/, "_").presence
  end

  has_many :observations, class_name: "WardObservation", foreign_key: :asset_id, inverse_of: :asset, dependent: :destroy

  validates :ref, presence: true, uniqueness: true
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :exposure, inclusion: { in: EXPOSURES }, allow_nil: true

  before_create { self.id ||= ULID.generate }

  scope :present, -> { where(gone_at: nil) }
  scope :by_name, -> { order(:name) }
  # Has the component, by inventory or by a person's word, or is it.
  scope :with_component, lambda { |component|
    where("jsonb_exists(components, :c) OR jsonb_exists(COALESCE(declared->'components', '[]'::jsonb), :c) OR " \
          "regexp_replace(lower(name), '[\\s-]+', '_', 'g') = :c",
          c: component_name(component))
  }

  def component_names
    (components.keys + Array(declared["components"])).map(&:to_s).uniq
  end

  def effective_exposure
    declared["exposure"].presence || exposure
  end

  # The version ward believes this asset runs of `component`, with the
  # observation it rests on. A probe or a person's observation wins over
  # Coolify's word when it was seen since Coolify's claim last changed:
  # what answers on the wire is the cross-check on what the control plane
  # says. -> [version, observation, disagreement or nil]
  def believed(component)
    latest = observations.where(component: self.class.component_name(component)).order(last_seen_at: :desc).to_a
    coolify = latest.find { |o| o.source == "coolify" }
    probe = latest.find { |o| o.source != "coolify" }
    chosen = if probe && (coolify.nil? || probe.last_seen_at >= coolify.first_seen_at) then probe else coolify || probe end
    return [ nil, nil, nil ] if chosen.nil?

    other = chosen == probe ? coolify : probe
    disagreement = other && other.version != chosen.version ? "#{other.source} says #{other.version}" : nil
    [ chosen.version, chosen, disagreement ]
  end

  # Record that `component` was seen at `version`: the same reading again
  # moves last_seen_at, a different one is a new row, so a change in what
  # runs is on the record with when it was first seen.
  def observe!(component:, version:, source:, digest: nil, principal: nil, started_at: nil, data: {}, at: Time.current)
    component = self.class.component_name(component)
    current = observations.where(component: component, source: source).order(last_seen_at: :desc).first
    if current && current.version == version.presence && current.digest == digest.presence && current.started_at == started_at
      current.update!(last_seen_at: at)
      current
    else
      observations.create!(component: component, version: version.presence, digest: digest.presence, source: source,
                           principal: principal, started_at: started_at, first_seen_at: at, last_seen_at: at, data: data.compact)
    end
  end

  def as_json_for_ward
    {
      "id" => id, "ref" => ref, "name" => name, "kind" => kind, "host" => host, "role" => role, "source" => source,
      "exposure" => effective_exposure, "image" => image, "tag" => tag, "digest" => digest,
      "components" => component_names.to_h { |c| [ c, believed(c).first ] },
      "declared" => declared.presence, "last_seen_at" => last_seen_at&.utc&.iso8601, "gone_at" => gone_at&.utc&.iso8601
    }.compact
  end
end
