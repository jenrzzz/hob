require "builder"

module Casts
  # The RSS a podcast app reads: the show, and each finished episode with
  # its audio and show notes (the stories it was made from, linked to their
  # sources). Every address in it carries the cast's token, which is the
  # only thing that keeps the feed private.
  module Feed
    ITUNES = "http://www.itunes.com/dtds/podcast-1.0.dtd".freeze
    CONTENT = "http://purl.org/rss/1.0/modules/content/".freeze
    LIMIT = 100

    module_function

    def url(cast, base)
      "#{base}/casts/#{cast.token}/feed.xml"
    end

    def audio_url(cast, episode, base)
      "#{base}/casts/#{cast.token}/episodes/#{episode.id}.mp3"
    end

    def xml(cast, base:)
      episodes = cast.episodes.ready.newest.limit(LIMIT).to_a
      out = Builder::XmlMarkup.new(indent: 2)
      out.instruct! :xml, version: "1.0", encoding: "UTF-8"
      out.rss(version: "2.0", "xmlns:itunes" => ITUNES, "xmlns:content" => CONTENT) do
        out.channel do
          out.title cast.title
          out.link base
          out.description cast.description.presence || cast.title
          out.language cast.setting(:language)
          out.lastBuildDate((episodes.first&.published_at || cast.updated_at).rfc2822)
          out.tag! "itunes:author", cast.setting(:author)
          out.tag! "itunes:explicit", "false"
          out.tag! "itunes:block", "Yes"
          out.tag! "itunes:image", href: cast.setting(:image_url) if cast.setting(:image_url).present?
          episodes.each { |episode| item(out, cast, episode, base) }
        end
      end
      out.target!
    end

    def item(out, cast, episode, base)
      out.item do
        out.title episode.title
        out.guid episode.id, isPermaLink: "false"
        out.pubDate episode.published_at.rfc2822
        out.description episode.summary.to_s
        out.tag!("content:encoded") { out.cdata! notes(episode) }
        out.enclosure url: audio_url(cast, episode, base), length: episode.audio_size, type: "audio/mpeg"
        out.tag! "itunes:duration", (episode.duration_ms.to_i / 1000).to_s
        out.tag! "itunes:episodeType", "full"
      end
    end

    # Show notes: what was said, and where each story came from.
    def notes(episode)
      h = ERB::Util.method(:html_escape)
      stories = episode.stories.map do |story|
        links = Array(story["sources"]).map do |s|
          %(<a href="#{h.(s['url'])}">#{h.(s['source'].presence || s['title'].presence || s['url'])}</a>)
        end
        "<li><strong>#{h.(story['title'])}</strong>#{" (#{links.join(', ')})" if links.any?}</li>"
      end
      "<p>#{h.(episode.summary)}</p>#{"<ul>#{stories.join}</ul>" if stories.any?}".gsub("]]>", "]]&gt;")
    end
  end
end
