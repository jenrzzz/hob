# What a podcast app fetches (CASTS.md, "Listening"): a cast's feed and its
# episodes' audio. A podcast app cannot send a bearer key, so there is none:
# the token in the path is the whole of the secret, and it opens exactly one
# cast, at that cast's realm, for reading. Rotating it (PATCH /v1/casts/:slug
# { rotate_token: true }) ends every subscription to the old address.
#
# GET /casts/:token/feed.xml
# GET /casts/:token/episodes/:id.mp3     Range and If-None-Match honoured
class CastFeedsController < ApplicationController
  skip_before_action :authenticate!, :gate_agents!
  skip_around_action :with_clearance
  around_action :as_the_cast

  def show
    response.headers["Cache-Control"] = "private, max-age=300"
    render xml: Casts::Feed.xml(@cast, base: public_base)
  end

  def audio
    episode = @cast.episodes.ready.find(params[:id])
    return head :not_modified if request.headers["If-None-Match"].to_s.delete('"') == episode.audio_key

    clip = episode.audio or raise ActiveRecord::RecordNotFound
    response.headers["ETag"] = %("#{episode.audio_key}")
    response.headers["Accept-Ranges"] = "bytes"
    response.headers["Cache-Control"] = "private, max-age=86400"
    first, last = byte_range(clip.size)
    return head :range_not_satisfiable, "Content-Range" => "bytes */#{clip.size}" if first == :unsatisfiable

    if first
      response.headers["Content-Range"] = "bytes #{first}-#{last}/#{clip.size}"
      send_data clip.bytes.byteslice(first..last), type: "audio/mpeg", disposition: "inline", status: :partial_content
    else
      send_data clip.bytes, type: "audio/mpeg", disposition: "inline", filename: "#{@cast.slug}-#{episode.edition}.mp3"
    end
  end

  private

  # The token names a cast whatever its realm, so it is looked up at the
  # top; everything after runs at the cast's own realm and no higher.
  def as_the_cast
    top = Realm.order(rank: :desc).pick(:slug)
    token = params[:token].to_s
    @cast = Clearance.with(top) { Cast.find_by(token: token) } if token.length >= 16
    return render json: { error: "not found" }, status: :not_found if @cast.nil?

    Clearance.with(@cast.realm) { yield }
  end

  def public_base
    ENV["HOB_CLIENT_URL"].presence&.chomp("/") || request.base_url
  end

  # A single "bytes=a-b", "bytes=a-" or "bytes=-n"; anything else is the
  # whole file. -> [first, last], [nil, nil], or [:unsatisfiable, nil]
  def byte_range(size)
    match = request.headers["Range"].to_s.match(/\Abytes=(\d*)-(\d*)\z/) or return [ nil, nil ]
    return [ nil, nil ] if match[1].empty? && match[2].empty?

    first, last = if match[1].empty?
      [ [ size - match[2].to_i, 0 ].max, size - 1 ]
    else
      [ match[1].to_i, match[2].empty? ? size - 1 : [ match[2].to_i, size - 1 ].min ]
    end
    first >= size || first > last ? [ :unsatisfiable, nil ] : [ first, last ]
  end
end
