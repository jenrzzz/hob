module V1
  # hob's own IRC (IRC.md), for a person to read from a surface (kat's
  # Upstairs). People read all of it and say nothing; the one thing written
  # here is a channel's seed tray (Irc::Pulse), which a surface fills with
  # things worth reacting to. The key's clearance decides, through RLS,
  # which channels and lines exist. Reading marks nothing.
  #
  #   GET /v1/irc/channels                    every channel and DM visible: realm, topic, members, line count
  #   GET /v1/irc/lines?target=#upstairs      the last `limit` lines, oldest first
  #                    &after=<id>            only lines after that one (following along)
  #                    &before=<id>           only lines before it (scrolling back)
  #                    &limit=100             at most Irc::MAX_READ
  #   GET  /v1/irc/seeds?target=#upstairs     its tray: waiting seeds, and the last ones taken
  #   POST /v1/irc/seeds                      { target, seeds: [{ kind, title?, body, key?, source? }] }
  #                                           planted at the channel's realm; a key already planted is skipped
  #
  # A DM's target is its row name, its two nicks in order: "meluzina,twilight".
  class IrcController < ApplicationController
    before_action :require_trusted!

    def channels
      rows = IrcChannel.order(:kind, :name).includes(:members).map do |channel|
        { name: channel.name, kind: channel.kind, realm: channel.realm, topic: channel.topic,
          members: Irc.nicks(channel), lines: channel.lines.spoken.count,
          last_line_at: channel.lines.maximum(:created_at)&.utc&.iso8601 }
      end
      render json: { channels: rows }
    end

    def lines
      channel = target or return

      limit = (params[:limit].presence || Irc::DEFAULT_READ).to_i.clamp(1, Irc::MAX_READ)
      scope = channel.lines
      scope = scope.where("irc_lines.id > ?", params[:after].to_i) if params[:after].present?
      scope = scope.where("irc_lines.id < ?", params[:before].to_i) if params[:before].present?
      lines = if params[:after].present?
        scope.order(:id).limit(limit).to_a
      else
        scope.order(id: :desc).limit(limit).to_a.reverse
      end

      render json: {
        channel: { name: channel.name, kind: channel.kind, realm: channel.realm, topic: channel.topic,
                   members: Irc.nicks(channel) },
        lines: lines.map { |line| { id: line.id, at: line.created_at.utc.iso8601, nick: line.nick, kind: line.kind, body: line.body } }
      }
    end

    TAKEN_SHOWN = 10
    PLANT_MAX = 50

    def seeds
      channel = target or return
      render json: {
        channel: channel.name, pulse: channel.pulse, pulse_state: channel.pulse_state.presence,
        hosts: channel.pulse && Irc::Pulse.new(channel).hosts.filter_map { |persona| PersonaLife.new(persona).agent&.name },
        waiting: channel.seeds.waiting.order(:id).map { |seed| seed_json(seed) },
        taken: channel.seeds.where.not(taken_at: nil).order(taken_at: :desc).limit(TAKEN_SHOWN).map { |seed| seed_json(seed) }
      }.compact
    end

    def plant
      channel = target or return
      rows = Array(params.require(:seeds))
      raise Gateway::Invalid, "at most #{PLANT_MAX} seeds at once" if rows.size > PLANT_MAX

      planted = []
      skipped = 0
      IrcSeed.transaction do
        rows.each do |row|
          row = deep_plain(row).to_h.stringify_keys
          key = row["key"].to_s.strip.presence
          if key && channel.seeds.exists?(key: key)
            skipped += 1
            next
          end

          planted << channel.seeds.create!(kind: row["kind"].to_s.strip.downcase, title: row["title"].to_s.strip.presence,
                                           body: row["body"].to_s.strip, key: key, source: row["source"].to_h,
                                           meant_for: meant_for(channel, row["for"]))
        end
      end
      render json: { planted: planted.map(&:id), skipped: skipped, waiting: channel.seeds.waiting.count }, status: :created
    end

    private

    def target
      channel = IrcChannel.find_by(name: params.require(:target).to_s.strip.downcase)
      render(json: { error: "there is no #{params[:target]}" }, status: :not_found) if channel.nil?
      channel
    end

    # The member a seed is for, by nick; nil for anyone's.
    def meant_for(channel, nick)
      nick = nick.to_s.strip.downcase
      return nil if nick.blank?

      channel.members.find { |member| member.name == nick } or raise Gateway::Invalid, "#{nick} is not in #{channel.name}"
    end

    def seed_json(seed)
      { id: seed.id, kind: seed.kind, title: seed.title, body: seed.body, key: seed.key, source: seed.source.presence,
        for: seed.meant_for&.name,
        created_at: seed.created_at.utc.iso8601, taken_at: seed.taken_at&.utc&.iso8601, taken_by: seed.taken_by&.name }.compact
    end
  end
end
