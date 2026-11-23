module V1
  # hob's own IRC (IRC.md), for a person to read from a surface (kat's
  # Upstairs). People read all of it and say nothing, so there is nothing
  # here to write with; the key's clearance decides, through RLS, which
  # channels and lines exist. Reading marks nothing.
  #
  #   GET /v1/irc/channels                    every channel and DM visible: realm, topic, members, line count
  #   GET /v1/irc/lines?target=#upstairs      the last `limit` lines, oldest first
  #                    &after=<id>            only lines after that one (following along)
  #                    &before=<id>           only lines before it (scrolling back)
  #                    &limit=100             at most Irc::MAX_READ
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
      channel = IrcChannel.find_by(name: params.require(:target).to_s.strip.downcase)
      return render(json: { error: "there is no #{params[:target]}" }, status: :not_found) if channel.nil?

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
  end
end
