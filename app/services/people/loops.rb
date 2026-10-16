module People
  # How loops follow from events (PEOPLE.md, "Loop"). Every event goes
  # through `apply!` once, as it is written, and nothing else opens or closes
  # a loop except a dictated loop (`open!`), a closing a caller names
  # (`close!`), and a person's dismissal.
  #
  #   inbound text or mail, 1:1        opens unanswered_inbound on that channel, or
  #                                    keeps the open one open (its age runs from the first)
  #   inbound anything                 closes awaiting_them: they answered
  #   outbound reached_out or replied  closes unanswered_inbound on its channel (any, if it has
  #                                    none) and owed_reply on any
  #   outbound or mutual call, meeting closes unanswered_inbound and owed_reply on every channel
  #   mutual                           closes awaiting_them too
  #
  # A loop closes only on an event at or after the time it opened, so a
  # reply hob sees late is never taken for an answer to what came after it.
  # Loops are per person and per principal: Jenner answering Eugene closes
  # Jenner's loop, not Tessa's. Group events open nothing: being one of nine
  # recipients is not being reached out to. Automated people, and handles a
  # person said never to open a loop for, open nothing either.
  module Loops
    OPENS = %w[reached_out replied].freeze
    OPENING_CHANNELS = %w[text email].freeze
    REPLIES = %w[reached_out replied].freeze
    CONTACT = %w[called met].freeze

    module_function

    # -> the loops this event opened or kept open, and those it closed.
    def apply!(event, handle: nil)
      return { opened: [], closed: [] } if event.person_id.nil? || !event.interaction?

      person = event.person
      outstanding = PeopleLoop.outstanding.where(person_id: person.identity_ids, principal_id: event.principal_id)
                              .where(opened_at: ..event.at)
      closed = []
      opened = []
      case event.direction
      when "inbound"
        closed += close_all!(outstanding.where(kind: "awaiting_them"), event)
        opened << unanswered!(event, person, handle) if opens?(event, person, handle) && !answered_since?(event, person)
      when "outbound"
        if REPLIES.include?(event.kind)
          answered = outstanding.where(kind: "unanswered_inbound")
          answered = answered.where(channel: event.channel) if event.channel
          closed += close_all!(answered, event)
          closed += close_all!(outstanding.where(kind: "owed_reply"), event)
        elsif CONTACT.include?(event.kind)
          closed += close_all!(outstanding.where(kind: %w[unanswered_inbound owed_reply]), event)
        end
      when "mutual"
        if CONTACT.include?(event.kind)
          closed += close_all!(outstanding.where(kind: %w[unanswered_inbound owed_reply awaiting_them]), event)
        end
      end
      { opened: opened.compact, closed: closed }
    end

    # A loop someone said is open: "I owe Tara the photos". Opened by the
    # event that recorded it.
    def open!(event, kind:, summary: nil)
      raise Invalid, "a loop's kind is one of #{PeopleLoop::KINDS.join(', ')}" unless PeopleLoop::KINDS.include?(kind)

      PeopleLoop.create!(person: event.person, group: event.group, principal: event.principal, kind: kind,
                         channel: event.channel, opened_by: event, latest_event: event, opened_at: event.at,
                         summary: summary.presence || event.summary, realm: event.realm)
    end

    def close!(loop, event, state: "closed")
      loop.update!(state: state, closed_by: event, closed_at: event.at, snoozed_until: nil)
      loop
    end

    def opens?(event, person, handle)
      OPENS.include?(event.kind) && OPENING_CHANNELS.include?(event.channel) && event.group_id.nil? &&
        !person.automated && (handle.nil? || handle.opens_loops)
    end

    # Whether the household already answered on this channel after this
    # event: a message read back late (hob:people:backfill) is not news.
    def answered_since?(event, person)
      PeopleEvent.interactions.where(person_id: person.identity_ids, principal_id: event.principal_id, group_id: nil)
                 .where("at > ?", event.at)
                 .where("(direction = 'outbound' AND kind IN (?) AND channel = ?) OR (direction IN ('outbound', 'mutual') AND kind IN (?))",
                        REPLIES, event.channel, CONTACT)
                 .exists?
    end

    # The open unanswered_inbound on this channel, kept open by this event
    # (and woken from a snooze: a new message is news), or a new one.
    def unanswered!(event, person, handle)
      loop = PeopleLoop.outstanding.where(person_id: person.identity_ids, principal_id: event.principal_id,
                                          kind: "unanswered_inbound", channel: event.channel).order(:opened_at).first
      if loop
        changes = { realm: higher(loop.realm, event.realm) }
        if event.at >= loop.latest_event.at
          changes.merge!(latest_event: event, snoozed_until: nil, summary: event.summary.presence || loop.summary)
        end
        changes.merge!(opened_by: event, opened_at: event.at) if event.at < loop.opened_at # read back late: the silence began earlier
        loop.update!(changes)
        return loop
      end

      PeopleLoop.create!(person: person, principal_id: event.principal_id, kind: "unanswered_inbound", channel: event.channel,
                         handle: handle, opened_by: event, latest_event: event, opened_at: event.at, summary: event.summary,
                         realm: event.realm)
    end

    def close_all!(scope, event)
      scope.to_a.each { |loop| close!(loop, event) }
    end

    def higher(a, b)
      Realm.rank_of(a) >= Realm.rank_of(b) ? a : b
    end
  end
end
