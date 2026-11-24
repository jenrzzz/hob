# Making an episode (CASTS.md): a model call, a dozen voice calls, and a
# mix, which together run for minutes, so never in the request that asked.
# It runs at the episode's own realm, as the surface that handed it over.
# Producer leaves the outcome on the row whatever happens, and every paid
# step is cached, so a failed episode is retried by a person
# (POST .../episodes/:id/retry), never by the queue.
class CastEpisodeJob < ApplicationJob
  queue_as :default

  def perform(episode_id)
    top = Realm.order(rank: :desc).pick(:slug)
    episode = Clearance.with(top) { CastEpisode.find_by(id: episode_id) } or return
    return if episode.ready?

    Clearance.with(episode.realm) do
      Current.set(surface: episode.surface.presence || "cast") { Casts::Producer.call(episode) }
    end
  rescue StandardError => e
    Rails.error.report(e, handled: true, severity: :error, source: "hob.cast")
  end
end
