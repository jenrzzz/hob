# Server-sent events for the two model-calling endpoints. One line per event:
# data: {"type": "delta"|"retry"|"usage"|"done"|"error", ...}
module SseStreaming
  extend ActiveSupport::Concern

  included do
    include ActionController::Live
  end

  private

  def stream_events
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    yield
  rescue Gateway::Refused => e
    sse_write(type: "done", status: "refused", error: e.message)
  rescue StandardError => e
    sse_write(type: "error", message: e.message, status: sse_status_for(e))
  ensure
    response.stream.close
  end

  # The block Gateway.complete streams into.
  def sse_gateway_events
    proc do |type, text|
      case type
      when :delta then sse_write(type: "delta", content: text)
      when :retry then sse_write(type: "retry", reason: text)
      end
    end
  end

  def sse_write(payload)
    response.stream.write("data: #{JSON.generate(payload)}\n\n")
  end

  def sse_status_for(error)
    case error
    when Gateway::RateLimited then "rate_limited"
    when Gateway::Unavailable then "unavailable"
    when Gateway::Invalid, ArgumentError then "invalid"
    else "error"
    end
  end
end
