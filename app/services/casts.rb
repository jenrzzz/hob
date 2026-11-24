# Casts (CASTS.md): hob as a producer. A surface hands over something worth
# hearing (feedcurator's morning briefing); hob writes it as two people
# talking, has them voiced, dresses it with a theme and stingers, mixes it
# to one file, and serves it on a private podcast feed.
#
#   Casts::Script    what the hosts say, written by a model and tidied
#   Casts::Pacer     how long the quiet between two takes is
#   Casts::Timeline  where every clip sits in the episode
#   Casts::Mixer     ffmpeg, making one mp3 of it
#   Casts::Producer  the whole run for one episode
#   Casts::Feed      the RSS a podcast app reads
module Casts
  class Error < StandardError; end
  class Invalid < Error; end

  module_function

  # Take what a surface hands over as the episode for `edition`, and start
  # making it. A cast has one episode per edition: one already made (or
  # being made) is handed back as it is, since making it again costs money;
  # `force` remakes it, and a failed one is always tried again.
  # -> [episode, started?]
  def submit!(cast, edition:, title:, briefing:, stories: [], force: false)
    edition = edition.to_s.strip
    raise Invalid, "an episode needs an edition: the surface's name for it, a date usually" if edition.blank?
    raise Invalid, "an episode needs a briefing: the text it is made from" if briefing.to_s.strip.blank?

    source = { "briefing" => briefing.to_s, "stories" => stories_of(stories) }
    episode = cast.episodes.find_by(edition: edition)
    if episode
      return [ episode, false ] if !force && (episode.ready? || episode.in_hand?)

      episode.update!(title: title.presence || episode.title, source: source, script: {}, status: "queued", error: nil,
                      surface: Current.surface)
    else
      episode = cast.episodes.create!(edition: edition, title: title.presence || "#{cast.title}, #{edition}", source: source,
                                      realm: cast.realm, surface: Current.surface)
    end
    CastEpisodeJob.perform_later(episode.id)
    [ episode, true ]
  rescue ActiveRecord::RecordNotUnique
    [ cast.episodes.find_by!(edition: edition), false ]
  end

  # Make a failed (or stuck) episode again from the script it already has,
  # so only what was never voiced is paid for. `rewrite` starts from the
  # briefing instead.
  def retry!(episode, rewrite: false)
    raise Invalid, "episode #{episode.id} is being made" if episode.in_hand?

    episode.update!(status: "queued", error: nil, script: rewrite ? {} : episode.script)
    CastEpisodeJob.perform_later(episode.id)
    episode
  end

  # Episodes past the show's `keep`, oldest first, and the audio of each.
  def prune!(cast)
    keep = cast.setting(:keep).to_i
    return 0 unless keep.positive?

    stale = cast.episodes.ready.newest.offset(keep).to_a
    stale.each do |episode|
      AudioClip.where(realm: episode.realm, key: episode.audio_key).delete_all if episode.audio_key
      episode.destroy
    end
    stale.size
  end

  # [{ title, summary, category, sources: [{ title, url, source }] }], and
  # nothing a surface might also have sent.
  def stories_of(stories)
    Array(stories).first(40).filter_map do |story|
      story = story.to_h.stringify_keys
      next if story["title"].blank?

      { "title" => story["title"].to_s.truncate(300), "summary" => story["summary"].to_s.truncate(4_000),
        "category" => story["category"].presence,
        "sources" => Array(story["sources"]).first(8).filter_map do |s|
          s = s.to_h.stringify_keys
          next unless s["url"].to_s.match?(%r{\Ahttps?://})

          { "title" => s["title"].to_s.truncate(300), "url" => s["url"].to_s, "source" => s["source"].presence }.compact
        end }.compact
    end
  end
end
