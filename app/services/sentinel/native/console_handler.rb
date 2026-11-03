module Sentinel
  module Native
    # What the console.* handlers share (KVM.md). They are thin: Consoles
    # does the work, at the agent's clearance, so the consoles an agent can
    # reach are the ones RLS shows it, and a session is reached only by the
    # agent that opened it. Everything handed back carries Consoles::NOTICE:
    # a screen shows whatever was on it.
    #
    # The frame goes back as an image (Native::IMAGES), never inside the
    # result: the request row keeps the arguments, the session, and the
    # frame's size, and not the picture.
    class ConsoleHandler < Base
      SESSION = { "type" => "string", "description" => "A session id, as console.open returned it" }.freeze
      SCALE = { "type" => "integer", "minimum" => Consoles::MIN_SCALE, "maximum" => Consoles::MAX_SCALE,
                "description" => "Width to scale the frame to (default 1280). Coordinates you send afterwards are in " \
                                 "the newest frame's pixels" }.freeze
      STATE = "Returns { session: { id, console, machine, goal, status, steps, expires_at }, video: { ready, error?, " \
              "width, height, fps }, screen: { width, height }, notice }, and the screen itself as an image. Coordinates " \
              "are pixels in the newest image, at its size (screen.width × screen.height), origin top left.".freeze

      private

      def framed(result)
        screen = result["screen"]
        images = []
        if screen.is_a?(Hash)
          images << { "data" => screen["data"], "mimeType" => screen["mime_type"].presence || "image/png" } if screen["data"].present?
          result = result.merge("screen" => screen.slice("width", "height"))
        end
        result.merge("notice" => Consoles::NOTICE, IMAGES => images)
      end
    end
  end
end
