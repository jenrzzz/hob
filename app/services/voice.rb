# The voice plane (DESIGN.md, "Voice"; CASTS.md): audio from a provider,
# asked for by model *role* like everything else, kept by what was asked
# (AudioClip) so the same line, sting, or theme is paid for once, and
# written to the same ledger as every completion.
#
#   Voice.dialogue([{ "voice_id" =>, "text" => }, ...], realm:)  -> AudioClip
#   Voice.sound("a short marimba flourish", seconds: 2.5, realm:) -> AudioClip
#   Voice.music("a jazzy morning theme", seconds: 40, realm:)     -> AudioClip
#
# A voice model's price row (ModelPrice, hob:price) reads `input` as USD per
# million *characters* asked; with no row the ledger's cost is null, as for
# any unpriced model.
module Voice
  class Error < StandardError; end
  class NotConfigured < Error; end
  class Invalid < Error; end
  class RateLimited < Error; end

  ROLES = { "dialogue" => "voice-dialogue", "sound" => "voice-sound", "music" => "voice-music" }.freeze
  # One request's worth of dialogue: the provider's own bound for a take
  # that stays reliable.
  DIALOGUE_MAX_CHARACTERS = 2_000

  module_function

  # Lines spoken as one take, each in its own voice. `settings` are the
  # provider's (stability, ...) and part of what names the clip.
  def dialogue(lines, realm:, ref: nil, settings: {}, language: nil)
    lines = Array(lines).map { |l| l.to_h.stringify_keys.slice("voice_id", "text") }
    raise Invalid, "dialogue needs lines" if lines.empty?
    raise Invalid, "every line needs a voice_id and text" if lines.any? { |l| l["voice_id"].blank? || l["text"].blank? }

    characters = lines.sum { |l| l["text"].length }
    raise Invalid, "a take is at most #{DIALOGUE_MAX_CHARACTERS} characters (#{characters})" if characters > DIALOGUE_MAX_CHARACTERS

    produce("dialogue", [ lines, settings, language ], realm: realm, ref: ref, characters: characters) do |client, model|
      client.dialogue(lines, model: model, settings: settings, language: language)
    end
  end

  def sound(prompt, seconds:, realm:, ref: nil)
    prompt = prompt.to_s.squish
    raise Invalid, "a sound needs a description" if prompt.blank?

    seconds = seconds.to_f.clamp(0.5, 30.0).round(1)
    produce("sound", [ prompt, seconds ], realm: realm, ref: ref, characters: prompt.length, seconds: seconds) do |client, model|
      client.sound(prompt, model: model, seconds: seconds)
    end
  end

  def music(prompt, seconds:, realm:, ref: nil)
    prompt = prompt.to_s.squish
    raise Invalid, "music needs a description" if prompt.blank?

    seconds = seconds.to_i.clamp(3, 600)
    produce("music", [ prompt, seconds ], realm: realm, ref: ref, characters: prompt.length, seconds: seconds) do |client, model|
      client.music(prompt, model: model, seconds: seconds)
    end
  end

  def available?(kind = "dialogue")
    resolve(kind)
    true
  rescue Error, Gateway::Error
    false
  end

  # -> [client, resolution] for a kind of audio.
  def resolve(kind)
    resolution = ModelRole.resolve!(ROLES.fetch(kind))
    unless resolution.provider.kind == "elevenlabs"
      raise NotConfigured, "role #{ROLES[kind]} resolves to #{resolution.provider.slug}, which is not a voice provider"
    end

    [ ElevenLabs.new(resolution.provider), resolution ]
  rescue Gateway::NoProviderError => e
    raise NotConfigured, "#{e.message} (is ELEVENLABS_API_KEY set?)"
  end

  # The cached clip for this ask, or a fresh one: generated, metered, kept.
  def produce(kind, material, realm:, ref:, characters:, seconds: nil)
    client, resolution = resolve(kind)
    key = AudioClip.key_for(kind, resolution.model, material)
    cached = AudioClip.lookup(realm: realm, key: key)
    return cached if cached

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ledger = { role: ROLES[kind], provider: resolution.provider.slug, model: resolution.model, operation: "voice.#{kind}",
               ref: ref, realm: realm, principal: Current.principal, surface: Current.surface,
               units: { "characters" => characters, "seconds" => seconds }.compact }
    begin
      bytes = yield client, resolution.model
    rescue Error => e
      UsageEvent.record(**ledger, status: e.is_a?(RateLimited) ? "rate_limited" : "error", error: e.message.truncate(500),
                                  duration_ms: elapsed_ms(started), cost: nil)
      raise
    end
    UsageEvent.record(**ledger, status: "success", duration_ms: elapsed_ms(started),
                                cost: cost(resolution.model, characters), metadata: { "audio_bytes" => bytes.bytesize })
    AudioClip.store!(realm: realm, key: key, kind: kind, bytes: bytes,
                     meta: { "model" => resolution.model, "characters" => characters, "seconds" => seconds }.compact)
  end

  def cost(model, characters)
    price = ModelPrice.for_model(model) or return nil

    (characters.to_i * price.input.to_d / 1_000_000).round(6)
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
end
