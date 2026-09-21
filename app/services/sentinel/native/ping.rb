module Sentinel
  module Native
    # hob.ping: liveness check — answers pong with the server's UTC time,
    # echoing back an optional short string.
    class Ping < Base
      CAPABILITY = {
        "name" => "hob.ping",
        "description" => "Liveness check: answers pong with the server's UTC time, echoing back an optional short string.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "echo" => { "type" => "string", "maxLength" => 200, "description" => "Optional text to return unchanged." }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = { "pong" => true, "at" => Time.now.utc.iso8601 }
        if arguments.key?("echo")
          echo = arguments["echo"]
          raise Error, "echo must be a String" unless echo.is_a?(String)
          raise Error, "echo exceeds 200 characters (#{echo.length})" if echo.length > 200
          result["echo"] = echo
        end
        result
      end
    end
  end
end
