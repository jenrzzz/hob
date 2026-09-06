ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/hob_world"

module ActiveSupport
  class TestCase
    include HobWorld

    setup do
      Gateway.transport = @fake = Gateway::Fake.new
      seed_world!
      clearance!("intimate")
      Current.principal = @principal
      Current.surface = "test"
    end

    teardown do
      Gateway.transport = nil
      Current.reset
    end
  end
end

class ActionDispatch::IntegrationTest
  # Controllers RESET app.clearance after each request; put it back so the
  # test can read RLS tables afterwards.
  %i[get post patch put delete].each do |verb|
    define_method(verb) do |*args, **kwargs|
      super(*args, **kwargs).tap { clearance!("intimate") }
    end
  end

  def auth(extra = {})
    { "Authorization" => "Bearer #{@token}" }.merge(extra)
  end

  def body
    JSON.parse(response.body)
  end

  def sse_events
    response.body.scan(/^data: (.*)$/).flatten.map { |line| JSON.parse(line) }
  end
end
