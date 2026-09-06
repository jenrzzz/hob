require "net/http"
require "uri"
require "json"

module Hob
  # Net::HTTP, JSON bodies, bearer auth, and hob's SSE stream. Maps HTTP
  # outcomes onto Hob's errors in one place.
  class HTTP
    attr_reader :base

    def initialize(base:, key:, timeout: 120, open_timeout: 10, clearance: nil)
      @base = URI(base.to_s.sub(%r{/+\z}, ""))
      @key = key
      @timeout = timeout
      @open_timeout = open_timeout
      @clearance = clearance
    end

    def get(path, query = nil)
      request(Net::HTTP::Get.new(uri_for(path, query)))
    end

    def post(path, body)
      request(Net::HTTP::Post.new(uri_for(path)), body)
    end

    def patch(path, body)
      request(Net::HTTP::Patch.new(uri_for(path)), body)
    end

    # POST with Accept: text/event-stream; yields each event as it arrives
    # and returns the terminal `done` event. An `error` event raises.
    def stream(path, body)
      req = Net::HTTP::Post.new(uri_for(path))
      req["Accept"] = "text/event-stream"
      parser = SSE.new
      done = nil
      perform(req, body) do |response|
        raise error_for(response, read_json(response.body)) unless response.code.to_i == 200

        response.read_body do |chunk|
          parser.feed(chunk) do |event|
            case event.type
            when "done" then done = event
            when "error" then raise stream_error(event)
            end
            yield event if block_given?
          end
        end
      end
      raise Unavailable, "stream ended without a done event" if done.nil?

      done.to_h
    end

    # Incremental parser for `data: {...}\n\n` frames.
    class SSE
      def initialize
        @buffer = +""
      end

      def feed(chunk)
        @buffer << chunk
        while (index = @buffer.index("\n\n"))
          frame = @buffer.slice!(0, index + 2)
          data = frame.lines.filter_map { |l| l.start_with?("data:") && l.sub(/\Adata: ?/, "").chomp }.join("\n")
          yield Event.new(JSON.parse(data)) unless data.empty?
        end
      end
    end

    # Errors as hob's status codes and stream events mean them.
    module Errors
      module_function

      def for_response(status, data, retry_after: nil)
        message = (data.is_a?(Hash) && (data["error"] || data["message"])) || "HTTP #{status}"
        opts = { status: status, body: data }
        case status
        when 401 then Unauthorized.new(message, **opts)
        when 404 then NotFound.new(message, **opts)
        when 400, 403, 422 then Invalid.new(message, **opts)
        when 429 then RateLimited.new(message, retry_after: retry_after, **opts)
        when 502 then Unauthorized.new(message, **opts)
        when 503
          if data.is_a?(Hash) && data["status"] == "rate_limited"
            RateLimited.new(message, retry_after: retry_after, **opts)
          else
            Unavailable.new(message, **opts)
          end
        when 500..599 then Unavailable.new(message, **opts)
        else Error.new(message, **opts)
        end
      end

      def for_event(event)
        message = event.message || "stream error"
        case event.status
        when "rate_limited" then RateLimited.new(message, body: event.to_h)
        when "unavailable" then Unavailable.new(message, body: event.to_h)
        when "invalid" then Invalid.new(message, body: event.to_h)
        else Error.new(message, body: event.to_h)
        end
      end
    end

    private

    def uri_for(path, query = nil)
      uri = @base.dup
      uri.path = "#{@base.path}#{path}"
      query = query&.compact
      uri.query = URI.encode_www_form(query) if query && !query.empty?
      uri
    end

    def request(req, body = nil)
      perform(req, body) do |response|
        data = read_json(response.body)
        raise error_for(response, data) unless response.code.start_with?("2")

        return data
      end
    end

    def perform(req, body)
      req["Authorization"] = "Bearer #{@key}"
      req["X-Hob-Clearance"] = @clearance if @clearance
      req["Accept"] ||= "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      http = Net::HTTP.new(@base.host, @base.port)
      http.use_ssl = @base.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @timeout
      http.start { |session| session.request(req) { |response| yield response } }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
      raise Unavailable, "hob unreachable at #{@base}: #{e.message}"
    end

    def read_json(body)
      return {} if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      { "error" => body }
    end

    def error_for(response, data)
      retry_after = response["Retry-After"]
      Errors.for_response(response.code.to_i, data, retry_after: retry_after && retry_after.to_i)
    end

    def stream_error(event)
      Errors.for_event(event)
    end
  end
end
