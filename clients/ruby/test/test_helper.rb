require "minitest/autorun"
require_relative "../lib/hob"

# Scripted HTTP for client tests: queue responses, inspect requests.
class FakeHTTP
  Request = Struct.new(:method, :path, :body, :query, :stream, keyword_init: true)

  attr_reader :requests

  def initialize
    @responses = []
    @requests = []
  end

  def respond(data)
    @responses << data
    self
  end

  def raise_with(error)
    @responses << error
    self
  end

  # events: the SSE frames a streamed request will yield, in order.
  def stream_events(*events)
    @responses << events
    self
  end

  def get(path, query = nil)
    take(Request.new(method: :get, path: path, query: query))
  end

  def post(path, body)
    take(Request.new(method: :post, path: path, body: body))
  end

  def patch(path, body)
    take(Request.new(method: :patch, path: path, body: body))
  end

  def stream(path, body)
    events = take(Request.new(method: :post, path: path, body: body, stream: true))
    done = nil
    events.each do |e|
      event = Hob::Event.new(e)
      raise Hob::HTTP::Errors.for_event(event) if event.type == "error"

      done = event if event.type == "done"
      yield event if block_given?
    end
    done.to_h
  end

  private

  def take(request)
    @requests << request
    raise "FakeHTTP: nothing queued for #{request.method} #{request.path}" if @responses.empty?

    item = @responses.shift
    raise item if item.is_a?(Exception)

    item
  end
end
