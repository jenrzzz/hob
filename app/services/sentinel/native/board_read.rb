module Sentinel
  module Native
    # hob.board.read: the household message board — skipsy and Marley's
    # shared, threaded coordination space (SENTINEL.md). No thread: the
    # index of threads, newest activity first, no post bodies. A thread: its
    # posts in order. RLS on board_posts (realm column) is what actually
    # keeps personal/intimate threads out of sight; this handler adds no
    # filtering of its own and performs no writes.
    class BoardRead < Base
      CAPABILITY = {
        "name" => "hob.board.read",
        "description" => "Read the household message board shared between household agents: with no thread given it " \
                         "returns the index of threads (topic, last activity, post count); with a thread given it " \
                         "returns that thread's posts in order, each stamped with sender agent and principal.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "limit" => { "type" => "integer", "default" => 50, "maximum" => 200, "minimum" => 1 },
            "since" => { "type" => "string", "format" => "date-time",
                        "description" => "Only return posts created after this instant (for polling)." },
            "thread" => { "type" => "string", "description" => "Thread id or slug. Omit to get the thread index." }
          },
          "additionalProperties" => false
        }
      }.freeze

      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      def call
        thread_ref = thread_ref!
        thread_ref ? thread_result(thread_ref) : index_result
      end

      private

      def index_result
        rows = BoardPost.group(:thread_id, :thread_slug, :thread_topic)
                        .select("thread_id, thread_slug, thread_topic, MAX(created_at) AS last_post_at, COUNT(*) AS post_count")
                        .order(Arel.sql("MAX(created_at) DESC"))
                        .limit(limit!)
        { "threads" => rows.map { |r| { "id" => r.thread_id, "slug" => r.thread_slug, "topic" => r.thread_topic,
                                         "post_count" => r.post_count.to_i, "last_post_at" => r.last_post_at.utc.iso8601 } } }
      end

      def thread_result(thread_ref)
        base = BoardPost.in_thread(thread_ref)
        raise Error, "no thread #{thread_ref.inspect}" unless base.exists?

        scope = base.order(created_at: :asc).includes(:sender_agent, :sender_principal)
        scope = scope.where("created_at > ?", since!) if arguments["since"].present?
        posts = scope.limit(limit!).to_a

        first = base.first
        {
          "posts" => posts.map { |p| post_json(p) },
          "thread" => { "id" => first.thread_id, "slug" => first.thread_slug, "topic" => first.thread_topic,
                       "post_count" => base.count, "last_post_at" => base.maximum(:created_at).utc.iso8601 },
          "next_since" => posts.last&.created_at&.utc&.iso8601
        }
      end

      def post_json(post)
        { "id" => post.id, "body" => post.body, "links" => post.links, "created_at" => post.created_at.utc.iso8601,
          "sender_agent" => post.sender_agent.name, "sender_principal" => post.sender_principal.name }
      end

      def thread_ref!
        raw = arguments["thread"]
        return nil if raw.blank?
        raise Error, "thread must be a string, got #{raw.inspect}" unless raw.is_a?(String)

        raw
      end

      def limit!
        raw = arguments["limit"]
        return DEFAULT_LIMIT if raw.blank?

        limit = Integer(raw)
        raise Error, "limit must be at least 1" if limit < 1

        limit.clamp(1, MAX_LIMIT)
      rescue ArgumentError, TypeError
        raise Error, "limit must be an integer, got #{raw.inspect}"
      end

      def since!
        raw = arguments["since"]
        time = raw.is_a?(String) ? Time.zone.parse(raw) : nil
        raise Error, "since must be an ISO8601 date-time, got #{raw.inspect}" if time.nil?

        time
      rescue ArgumentError
        raise Error, "since must be an ISO8601 date-time, got #{raw.inspect}"
      end
    end
  end
end
