module People
  # Where events come from without anyone writing them down (PEOPLE.md):
  # every text backend's stream, sent and received, read with Texts.poll on
  # a cursor kept in people_cursors, each message becoming one event and
  # going through People::Loops. Run by PeopleSyncJob on hob's clock, and by
  # hob:people:sync and hob:people:backfill from a terminal.
  #
  # An event cites its message (`source_ref`, the text's id) and keeps none
  # of its body: the summary says who, which way, and where, nothing the
  # sender wrote. A handle hob has never seen becomes a person, named as the
  # backend's Contacts name them, in the backend's realm, the backend
  # owner's; err toward duplication, and let a person merge.
  #
  # A 1:1 chat's messages are the person's events and may open or close
  # loops. A group chat's are the group's: they keep its membership and its
  # log, and open nothing. Messages a sender unsent are skipped, and so is
  # any message already derived, so running twice is running once.
  #
  # Runs at whatever clearance it is given; the job gives it intimate, so
  # every backend is in sight.
  module Sync
    SURFACE = "people-sync".freeze
    PAGES = 20
    CHATS = 200
    BACKFILL_LIMIT = 5000

    Report = Struct.new(:backend, :seen, :derived, :opened, :closed, :error, keyword_init: true) do
      def to_s
        error ? "#{backend}: #{error}" : "#{backend}: #{seen} seen, #{derived} new events, #{opened} loops opened, #{closed} closed"
      end
    end

    module_function

    def run!
      TextBackend.enabled.order(:name).map { |backend| backend!(backend) }
    end

    # Read one backend's stream from its cursor; a first run only notes
    # where the stream is now (hob:people:backfill reads back from there).
    def backend!(backend)
      row = PeopleCursor.find_or_initialize_by(source: "text:#{backend.name}") { |r| r.realm = backend.realm }
      report = Report.new(backend: backend.name, seen: 0, derived: 0, opened: 0, closed: 0)
      deriver = Deriver.new(backend)
      PAGES.times do
        result = Texts.poll("backend" => backend.name, "cursor" => row.cursor, "include_sent" => true)
        result["messages"].each { |message| tally(report, deriver.derive!(message)) }
        row.cursor = result["cursor"]
        break unless result["more"]
      end
      row.update!(synced_at: Time.current, last_error: nil)
      report
    rescue Texts::Error => e
      row.update!(last_error: "#{e.class.name.demodulize}: #{e.message}".truncate(2000))
      report.error = e.message
      report
    end

    # Read back over what a backend already holds, oldest first, from
    # `since`: what arrived before the first run. Safe to repeat.
    def backfill!(backend, since:)
      report = Report.new(backend: backend.name, seen: 0, derived: 0, opened: 0, closed: 0)
      found = []
      before = nil
      loop do
        filters = { "backend" => backend.name, "after" => since.iso8601, "limit" => Texts::MAX_LIMIT }
        filters["before"] = before if before
        page = Texts.messages(filters)
        found.concat(page["messages"])
        break unless page["truncated"] && page["messages"].any? && found.size < BACKFILL_LIMIT

        before = page["messages"].last["sent_at"]
      end
      deriver = Deriver.new(backend)
      found.uniq { |m| m["id"] }.sort_by { |m| m["sent_at"].to_s }.each { |message| tally(report, deriver.derive!(message)) }
      report
    rescue Texts::Error => e
      report.error = e.message
      report
    end

    # Start the Rolodex from a backend's chats rather than from recall: a
    # person for everyone in its most recent chats, a group for each group
    # chat, with its members. -> { people:, groups: } made or found.
    def seed!(backend)
      deriver = Deriver.new(backend)
      chats = Texts.chats("backend" => backend.name, "limit" => CHATS)["chats"]
      groups = chats.count { |chat| deriver.seed!(chat) == :group }
      { people: Person.live.count, groups: groups, chats: chats.size }
    end

    def tally(report, outcome)
      report.seen += 1
      return unless outcome

      report.derived += 1
      report.opened += outcome[:opened].size
      report.closed += outcome[:closed].size
    end

    # One backend's messages into events. Knows the backend's chats (asked
    # for once, when first needed) and which groups' members it has already
    # brought up to date this run.
    class Deriver
      def initialize(backend)
        @backend = backend
        @chats = nil
        @joined = {}
      end

      # -> { opened:, closed: } for a new event, nil for a message skipped.
      def derive!(message)
        return nil if message["unsent"] || message["id"].blank?
        return nil if PeopleEvent.exists?(source_kind: "text", source_ref: message["id"])

        PeopleEvent.transaction(requires_new: true) do
          group?(message) ? group_message!(message) : direct_message!(message)
        end
      rescue ActiveRecord::RecordNotUnique
        nil # another run derived it first
      end

      # One chat into people (and a group, for a group chat). -> :group or :direct
      def seed!(chat)
        (@chats ||= {})[chat["id"]] = chat
        if chat["group"]
          group = People.group_for_chat!("text:#{chat['id']}", name: chat["display_name"].presence || chat["name"],
                                                             realm: @backend.realm, principal: @backend.principal)
          join!(group, chat)
          return :group
        end

        participant = Array(chat["participants"]).first
        address = participant&.dig("handle").presence || chat["identifier"]
        People.observe!(address, name: participant&.dig("name") || chat["name"], realm: @backend.realm, principal: @backend.principal,
                                 by: @backend.principal) if address.present?
        :direct
      rescue People::Invalid
        :direct
      end

      private

      def direct_message!(message)
        address, name = counterpart(message)
        return nil if address.blank?

        person, handle = People.observe!(address, name: name, realm: @backend.realm, principal: @backend.principal, by: @backend.principal)
        direction = message["from_me"] ? "outbound" : "inbound"
        event = event!(message, person: person, direction: direction, kind: kind(person, direction),
                                summary: "#{summary(message, direction)} #{person.display_name}",
                                realm: People.higher(@backend.realm, person.realm))
        People::Loops.apply!(event, handle: handle)
      end

      def group_message!(message)
        chat = chat(message)
        group = People.group_for_chat!("text:#{message['chat_id']}", name: chat&.dig("display_name").presence || chat&.dig("name"),
                                                                     realm: @backend.realm, principal: @backend.principal)
        join!(group, chat)
        sender = nil
        if !message["from_me"] && message.dig("sender", "handle").present?
          sender, = People.observe!(message.dig("sender", "handle"), name: message.dig("sender", "name"), realm: @backend.realm,
                                                                    principal: @backend.principal, by: @backend.principal)
          People.member!(group, sender)
        end
        text = message["from_me"] ? "text in #{group.name}" : "text in #{group.name} from #{sender&.display_name || 'someone'}"
        event!(message, person: nil, group: group, direction: message["from_me"] ? "outbound" : "inbound",
                        kind: "reached_out", summary: with_attachments(text, message), realm: group.realm)
        { opened: [], closed: [] }
      end

      def event!(message, person:, direction:, kind:, summary:, realm:, group: nil)
        PeopleEvent.create!(person: person, group: group, at: Time.iso8601(message["sent_at"]), kind: kind, direction: direction,
                            channel: "text", summary: summary.truncate(PeopleEvent::SUMMARY_LIMIT), source_kind: "text",
                            source_ref: message["id"], principal: @backend.principal, recorded_by: @backend.principal,
                            surface: SURFACE, realm: realm)
      end

      # Replied if the last 1:1 text between them went the other way.
      def kind(person, direction)
        last = PeopleEvent.interactions.where(person_id: person.identity_ids, group_id: nil, channel: "text",
                                              principal_id: @backend.principal_id).order(at: :desc).first
        last && last.direction != direction ? "replied" : "reached_out"
      end

      def summary(message, direction)
        with_attachments(direction == "inbound" ? "text from" : "text to", message)
      end

      def with_attachments(text, message)
        count = Array(message["attachments"]).size
        return text if count.zero?

        message["text"].blank? ? "#{text} (#{count == 1 ? 'an attachment' : "#{count} attachments"})" : text
      end

      # The other end of a 1:1 chat: the sender of an incoming message, or
      # the chat's one participant (its identifier, if the chat is not known).
      def counterpart(message)
        return [ message.dig("sender", "handle"), message.dig("sender", "name") ] unless message["from_me"]

        chat = chat(message)
        participant = Array(chat&.dig("participants")).first
        return [ participant["handle"], participant["name"] ] if participant

        [ chat&.dig("identifier").presence || message["chat_id"].to_s.split(";").last, nil ]
      end

      def group?(message)
        chat = chat(message)
        return chat["group"] if chat

        message["chat_id"].to_s.split(":", 2).last.to_s.include?(";+;")
      end

      def chat(message)
        @chats ||= Texts.chats("backend" => @backend.name, "limit" => CHATS)["chats"].index_by { |c| c["id"] }
        @chats[message["chat_id"]]
      end

      def join!(group, chat)
        return if chat.nil? || @joined[group.id]

        @joined[group.id] = true
        Array(chat["participants"]).each do |participant|
          next if participant["handle"].blank?

          person, = People.observe!(participant["handle"], name: participant["name"], realm: @backend.realm,
                                                          principal: @backend.principal, by: @backend.principal)
          People.member!(group, person)
        rescue People::Invalid
          next # a participant handle hob cannot read as one
        end
      end
    end
  end
end
