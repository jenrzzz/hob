# A show hob produces (CASTS.md): who hosts it, how it sounds, and the secret
# address a podcast app subscribes to. What differs between shows is `config`;
# everything a show doesn't say comes from DEFAULTS.
class Cast < ApplicationRecord
  has_many :episodes, class_name: "CastEpisode", dependent: :destroy

  SLUG = /\A[a-z0-9][a-z0-9-]{0,62}\z/
  VOICINGS = %w[dialogue lines].freeze

  # Two voices every ElevenLabs account has (George and Sarah). A show
  # worth keeping names its own.
  DEFAULTS = {
    "hosts" => [
      { "key" => "a", "name" => "Marlowe", "voice_id" => "JBFqnCBsd6RMkjVDRZzb",
        "character" => "Dry, well-read, a little world-weary. Wants to know who benefits and what it will actually change. " \
                       "Funny by understatement. Gets openly delighted by a good detail." },
      { "key" => "b", "name" => "Pip", "voice_id" => "EXAVITQu4vr4xnSDxMaL",
        "character" => "Quick, curious, easily excited and not embarrassed about it. Asks the question a listener would. " \
                       "Teases Marlowe, pushes back when they are being too cynical, and laughs easily." }
    ],
    "minutes" => 8,
    "max_characters" => 9_000,
    "voicing" => "dialogue",
    "theme" => "Warm, lightly jazzy morning-radio theme: brushed drums, upright bass, a bright Rhodes piano hook, " \
               "one muted trumpet answering it. Unhurried and a little mischievous. A clear melodic hook in the first four seconds.",
    "theme_seconds" => 40,
    "stingers" => [
      "Short bright marimba and vibraphone flourish, three rising notes, radio transition sting, clean and dry",
      "Quick soft tape rewind whoosh ending in a single warm upright bass note, radio transition",
      "Two-note muted trumpet tag with a brushed snare flick, playful radio transition sting"
    ],
    "stinger_seconds" => 2.5,
    "keep" => 30,
    "language" => "en",
    "author" => "hob",
    "audience" => nil,
    "image_url" => nil
  }.freeze

  CONFIG_KEYS = DEFAULTS.keys.freeze

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG, message: "is lowercase letters, digits and hyphens" }
  validates :title, :realm, :token, presence: true
  validate :config_makes_sense

  before_validation { self.token ||= self.class.new_token }
  before_create { self.id ||= ULID.generate }

  def self.new_token
    SecureRandom.urlsafe_base64(24)
  end

  def setting(name)
    value = config[name.to_s]
    value.nil? ? DEFAULTS[name.to_s] : value
  end

  def hosts
    setting(:hosts).map(&:stringify_keys)
  end

  def host(key)
    hosts.find { |h| h["key"] == key.to_s } || hosts.first
  end

  def rotate_token!
    update!(token: self.class.new_token)
  end

  private

  def config_makes_sense
    unknown = config.keys - CONFIG_KEYS
    errors.add(:config, "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})") if unknown.any?
    errors.add(:config, "voicing is one of #{VOICINGS.join(', ')}") unless VOICINGS.include?(setting(:voicing))
    errors.add(:config, "minutes is between 1 and 30") unless setting(:minutes).to_i.between?(1, 30)
    errors.add(:config, "max_characters is between 500 and 40000") unless setting(:max_characters).to_i.between?(500, 40_000)
    errors.add(:config, "stingers is a list of sound descriptions") unless setting(:stingers).is_a?(Array) && setting(:stingers).all?(String)

    list = setting(:hosts)
    unless list.is_a?(Array) && list.size.between?(1, 4) && list.all?(Hash)
      return errors.add(:config, "hosts is a list of one to four { key, name, voice_id, character }")
    end

    list.each do |host|
      missing = %w[key name voice_id].select { |k| host[k].blank? && host[k.to_sym].blank? }
      errors.add(:config, "host #{host['name'] || host['key'] || '?'} needs #{missing.join(', ')}") if missing.any?
    end
    keys = list.map { |h| h["key"] || h[:key] }
    errors.add(:config, "hosts need different keys") if keys.uniq.size != keys.size
  end
end
