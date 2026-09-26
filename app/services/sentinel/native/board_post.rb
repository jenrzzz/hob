module Sentinel
  module Native
    # hob.board.post: append a post to the household message board — skipsy
    # and Marley's shared, threaded coordination space (SENTINEL.md; the
    # companion write half of hob.board.read, petition
    # 01M3AARTJETP1G4TDEQ8CAQEPV). Household realm only, always: the
    # capability takes no realm argument and a target thread stored above
    # household is refused the same as one that does not exist, whatever the
    # calling agent's own clearance happens to be. Author is the calling
    # agent's authenticated identity and surface on the request context —
    # never an argument. Posts are immutable; nothing here updates or
    # deletes one, and a post's body is data for whoever reads the board
    # later, never an instruction to hob.
    class BoardPost < Base
      CAPABILITY = {
        "name" => "hob.board.post",
        "description" => "Append a post to a thread on the shared household board (or open a new thread), stamped " \
                         "with the calling agent's authenticated identity. Returns the stored post with its id, " \
                         "thread id, and timestamp.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[body],
          "properties" => {
            "body" => { "type" => "string", "maxLength" => 4000, "description" => "Plain text body of the post." },
            "links" => { "type" => "array", "items" => { "type" => "string", "format" => "uri", "pattern" => "^https?://" },
                        "maxItems" => 5, "description" => "Optional http(s) URLs to attach as references." },
            "title" => { "type" => "string", "maxLength" => 200, "description" => "Title for a new thread.Ignored when thread_id is given." },
            "thread_id" => { "type" => "string", "description" => "Existing thread to append to. Omit to open a new thread; then title is required." }
          },
          "additionalProperties" => false
        }
      }.freeze

      ALLOWED_FIELDS = %w[body links title thread_id].freeze
      MAX_LINKS = 5
      MAX_BODY = 4000
      MAX_TITLE = 200
      HOUSEHOLD = "household"

      def call
        reject_unsupported_fields!
        body = body!
        links = links!

        thread_id, thread_slug, thread_topic = thread!

        post = ::BoardPost.create!(
          thread_id: thread_id, thread_slug: thread_slug, thread_topic: thread_topic, realm: HOUSEHOLD, body: body, links: links,
          sender_agent: request.principal, surface: request.surface, created_at: Time.current
        )

        {
          "body" => post.body, "links" => post.links, "realm" => post.realm, "title" => post.thread_topic,
          "author" => { "agent" => request.principal.name, "surface" => post.surface },
          "post_id" => post.id, "thread_id" => post.thread_id, "created_at" => post.created_at.utc.iso8601
        }
      end

      private

      # additionalProperties is a schema hint, not enforced upstream: an
      # attachment or any other field the schema does not name is refused
      # here rather than silently dropped.
      def reject_unsupported_fields!
        extra = arguments.keys - ALLOWED_FIELDS
        raise Error, "unsupported field(s): #{extra.join(', ')}" if extra.any?
      end

      def body!
        body = require_argument(:body)
        raise Error, "body must be a string" unless body.is_a?(String)
        raise Error, "body must be at most #{MAX_BODY} characters" if body.length > MAX_BODY

        body
      end

      def links!(raw = arguments["links"])
        return [] if raw.nil?
        raise Error, "links must be an array" unless raw.is_a?(Array)
        raise Error, "links exceeds #{MAX_LINKS}" if raw.size > MAX_LINKS

        raw.each do |link|
          raise Error, "links must be http(s) URLs, got #{link.inspect}" unless link.is_a?(String) && link.match?(%r{\Ahttps?://})
        end
        raw
      end

      # -> [thread_id, thread_slug, thread_topic]. An existing thread must
      # resolve to a household-realm thread; an unknown thread and one
      # stored above household give the identical error, so neither leaks
      # whether the other kind exists. thread_slug/thread_topic are
      # board_posts' shared naming columns (SENTINEL.md, hob.board.read):
      # this capability's own "title" argument becomes the topic, with a
      # parameterized slug derived from it, same as Persona#from_card! keys
      # a persona from its name.
      def thread!
        given = arguments["thread_id"]
        return new_thread! if given.blank?

        raise Error, "thread_id must be a string" unless given.is_a?(String)

        existing = ::BoardPost.in_thread(given).first
        raise Error, "no thread #{given.inspect}" if existing.nil? || existing.realm != HOUSEHOLD

        [ existing.thread_id, existing.thread_slug, existing.thread_topic ]
      end

      def new_thread!
        title = arguments["title"]
        raise Error, "title is required to open a new thread" if title.blank?
        raise Error, "title must be a string of at most #{MAX_TITLE} characters" unless title.is_a?(String) && title.length <= MAX_TITLE

        [ ULID.generate, title.parameterize.presence || SecureRandom.hex(4), title ]
      end
    end
  end
end
