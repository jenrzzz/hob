# The steward deciding a petition (SENTINEL.md, "Petitions and the forge"),
# off the request that filed it: the steward is the strongest model reading
# a long brief, and a slow answer used to outlast the proxy, so the agent
# got a 502 for a petition that had landed (skipsy, 2026-11-23). It runs at
# the petition's own realm, as the request did. Steward.process! leaves a
# decision on the row whatever happens, so nothing here retries.
class StewardJob < ApplicationJob
  queue_as :default

  def perform(petition_id)
    petition = Clearance.with("intimate") { Petition.find_by(id: petition_id) } or return
    Clearance.with(petition.realm) do
      Current.set(surface: petition.surface) { Sentinel::Steward.process!(petition) }
    end
  end
end
