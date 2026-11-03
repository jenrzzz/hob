module Consoles
  module Backends
    # An in-memory KVM with the bridge's surface, for tests: a Device per
    # console name, with one session at a time (a second open is busy, as
    # the bridge answers 409), a frame counter standing in for the screen,
    # and every action it was sent. It is a kind only in the test environment
    # (Consoles::Backends registers it there).
    #
    #   device = Consoles::Backends::Fake.device("jenner-mac")   # the row's name
    #   device.video = { "ready" => false, "error" => "no_signal" }
    #   device.take_over!                                         # a person opened the KVM in a browser
    #   Consoles::Backends::Fake.fail!("jenner-mac", Consoles::Unavailable.new("the bridge is down"))
    #   Consoles::Backends::Fake.reset!                           # in teardown
    class Fake < Base
      class Device
        attr_reader :sessions, :calls
        attr_accessor :error, :video, :frames

        def initialize
          @sessions = {}
          @calls = []
          @video = { "ready" => true, "width" => 1920, "height" => 1080, "fps" => 60 }
          @frames = 0
          @counter = 0
        end

        def next_id
          "k#{@counter += 1}"
        end

        def live
          sessions.values.find { |s| !s["closed"] }
        end

        def take_over!
          live&.store("closed", "another session connected to the KVM")
        end

        def expire!(remote_id)
          sessions.fetch(remote_id)["closed"] = "session expired"
        end
      end

      class << self
        def devices
          @devices ||= Hash.new { |devices, name| devices[name] = Device.new }
        end

        def device(name)
          devices[name]
        end

        def fail!(name, error)
          devices[name].error = error
        end

        def reset!
          @devices = nil
        end
      end

      def open(ttl:, scale:)
        failing!
        device.calls << [ :open, ttl, scale ]
        raise Consoles::Unavailable, "#{console.name} is in use by another session" if device.live

        session = { "id" => device.next_id, "ttl" => ttl, "scale" => scale || 1280, "closed" => nil }
        device.sessions[session["id"]] = session
        frame(session)
      end

      def state(remote_id, scale:)
        failing!
        session = live(remote_id)
        device.calls << [ :state, remote_id, scale ]
        session["scale"] = scale if scale
        frame(session)
      end

      def act(remote_id, body)
        failing!
        session = live(remote_id)
        device.calls << [ :act, remote_id, body ]
        frame(session)
      end

      def close(remote_id)
        failing!
        device.calls << [ :close, remote_id ]
        live(remote_id)["closed"] = "closed by the caller"
        true
      end

      def check(probe: false)
        failing!
        device.calls << [ :check, probe ]
        { "reachable" => true, "bridge" => "fake", "device" => { "version" => "0.5.10", "video" => device.video },
          "session" => device.live&.slice("id") }.compact
      end

      private

      def device
        Fake.device(console.name)
      end

      def failing!
        raise device.error if device.error
      end

      def live(remote_id)
        session = device.sessions[remote_id] or raise Consoles::NotFound, "no such session"
        raise Consoles::Gone, "session ended: #{session['closed']}" if session["closed"]

        session
      end

      def frame(session)
        n = device.frames += 1
        width = session["scale"]
        height = width * 1080 / 1920
        { "id" => session["id"], "expires_at" => (Time.now.utc + session["ttl"]).iso8601, "video" => device.video,
          "screen" => { "data" => Base64.strict_encode64("\x89PNG fake frame #{n}"), "mime_type" => "image/png",
                        "width" => width, "height" => height } }
      end
    end
  end
end
