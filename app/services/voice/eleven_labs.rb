require "net/http"

module Voice
  # ElevenLabs' generation endpoints, and the whole of what hob knows of
  # them: dialogue (several voices in one take), sound effects, music. Pure
  # HTTP; every method returns MP3 bytes. Keeping and metering them is
  # Voice's job. (kat's ElevenLabs::Client, extracted.)
  class ElevenLabs
    # Tests inject a lambda (verb, url, body, headers) -> [status, body], as
    # they do with the texts and todo backends, so nothing in the suite
    # touches the network.
    class_attribute :transport

    BASE = "https://api.elevenlabs.io".freeze
    OUTPUT_FORMAT = "mp3_44100_128".freeze
    OPEN_TIMEOUT = 10
    # A minute of music takes about a minute to compose.
    READ_TIMEOUT = 300
    RETRIES = 2
    RETRY_STATUSES = [ 429, 500, 502, 503, 504 ].freeze
    SOUND_TEXT_MAX = 450

    def initialize(provider)
      @provider = provider
      @key = provider.api_key or raise NotConfigured, "#{provider.config['api_key_env']} is not set"
      @base = provider.config["base_url"].presence || BASE
    end

    # lines: [{ "voice_id" =>, "text" => }]. Bracketed tags in the text
    # ([laughs], [sighs]) are performed by the v3 and v4 models, not read aloud.
    def dialogue(lines, model:, settings: {}, language: nil)
      body = { inputs: lines.map { |l| { text: l["text"], voice_id: l["voice_id"] } }, model_id: model }
      body[:settings] = settings if settings.present?
      body[:language_code] = language if language.present?
      audio("/v1/text-to-dialogue", body)
    end

    def sound(prompt, model:, seconds: nil, prompt_influence: 0.4)
      body = { text: prompt.truncate(SOUND_TEXT_MAX, separator: " ", omission: ""), model_id: model,
               prompt_influence: prompt_influence }
      body[:duration_seconds] = seconds if seconds
      audio("/v1/sound-generation", body)
    end

    def music(prompt, model:, seconds:, instrumental: true)
      audio("/v1/music", { prompt: prompt, model_id: model, music_length_ms: (seconds * 1000).to_i,
                           force_instrumental: instrumental })
    end

    private

    def audio(path, body)
      url = "#{@base}#{path}?output_format=#{OUTPUT_FORMAT}"
      headers = { "xi-api-key" => @key, "Content-Type" => "application/json", "Accept" => "audio/mpeg" }
      attempt = 0
      loop do
        status, payload = post(url, JSON.generate(body), headers)
        return payload.b if status.between?(200, 299) && payload.present?

        if RETRY_STATUSES.include?(status) && attempt < RETRIES
          attempt += 1
          pause(attempt)
          next
        end
        raise RateLimited, "ElevenLabs is rate limiting (429)" if status == 429

        raise Error, "ElevenLabs answered #{status}: #{detail(payload)}"
      end
    end

    def post(url, body, headers)
      return transport.call("POST", url, body, headers) if transport

      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.post(uri.request_uri, body, headers)
      end
      [ response.code.to_i, response.body.to_s ]
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError => e
      raise Error, "ElevenLabs could not be reached: #{e.class}: #{e.message}"
    end

    def pause(attempt)
      sleep(attempt * 2) unless transport
    end

    # ElevenLabs' errors are { detail: { status, message } } or { detail: "..." }.
    def detail(payload)
      parsed = JSON.parse(payload.to_s)
      inner = parsed["detail"]
      (inner.is_a?(Hash) ? inner["message"] || inner["status"] : inner).to_s.presence || payload.to_s.truncate(200)
    rescue JSON::ParserError
      payload.to_s.scrub.truncate(200)
    end
  end
end
