module Hob
  # Something memory is about: a person, a persona, a media item, a place.
  class Entity < Record
    attribute :id, :type, :name, :aliases, :ref, :created_at
  end

  # One timestamped fact about an entity, with its realm and provenance.
  # `author` is the entity of the persona who noted it, if one did.
  class Observation < Record
    attribute :id, :about, :author, :kind, :body, :realm, :observed_at, :status, :supersedes, :superseded_by,
              :retired_at, :retire_reason, :evidence, :provenance, :score, :reasons, :history, :created_at

    def current?
      status == "current"
    end
  end

  # A persona's sheet: { "section" => [{ "id", "text", "realm" }] } at a version.
  class Sheet < Record
    attribute :persona, :version, :sections
  end

  # One proposed, applied, rejected, or reverted change to a sheet.
  class SheetRevision < Record
    attribute :id, :persona, :version, :kind, :realm, :status, :ops, :rationale, :citations, :proposed_by,
              :proposed_via, :provenance, :rollback_to, :decided_by, :decided_at
  end

  # /v1/memory (MEMORY.md): deposit observations, ask what is known, read a
  # persona's file on someone. Writes land at the key's clearance (cap it with
  # Client.new(clearance:) to write lower); every read is at it.
  #
  #   hob.memory.deposit([{ about: "principal:jenner", body: "replayed scene 4 twice", kind: "evidence" }])
  #   hob.memory.recall(query: "what does he linger on", about: ["principal:jenner"], persona: "velvet")
  #   hob.memory.file(persona: "velvet", about: "principal:jenner")
  class Memory
    def initialize(http)
      @http = http
    end

    def entities(q: nil, type: nil, limit: nil)
      @http.get("/v1/memory/entities", { q: q, type: type, limit: limit })["entities"].map { |e| Entity.new(e) }
    end

    # By id or ref ("kat:media:30880").
    def entity(id)
      Entity.new(@http.get("/v1/memory/entities/#{id}"))
    end

    # Made, or the existing one with that ref.
    def create_entity(type:, name:, ref: nil, aliases: nil)
      Entity.new(@http.post("/v1/memory/entities", { type: type, name: name, ref: ref, aliases: aliases }.compact))
    end

    # One observation. about: an entity id, a ref, a name, or { type, name, ref } to make it.
    def remember(about:, body:, kind: nil, persona: nil, evidence: nil, observed_at: nil)
      deposit([ { about: about, body: body, kind: kind, persona: persona, evidence: evidence, observed_at: observed_at }.compact ]).first
    end

    # Up to 500, all or nothing.
    def deposit(observations)
      @http.post("/v1/memory/observations", { observations: observations })["observations"].map { |o| Observation.new(o) }
    end

    # The observation with its whole chain in `history`.
    def observation(id)
      Observation.new(@http.get("/v1/memory/observations/#{id}"))
    end

    def supersede(id, body:, kind: nil, evidence: nil, reason: nil)
      Observation.new(@http.post("/v1/memory/observations/#{id}/supersede", { body: body, kind: kind, evidence: evidence, reason: reason }.compact))
    end

    def retire(id, reason:)
      Observation.new(@http.post("/v1/memory/observations/#{id}/retire", { reason: reason }))
    end

    # Hybrid recall; each observation carries `score` and `reasons`.
    def recall(query: nil, about: nil, persona: nil, scope: nil, limit: nil, budget: nil)
      body = { query: query, about: about, persona: persona, scope: scope, limit: limit, budget: budget }.compact
      @http.post("/v1/memory/recall", body)["observations"].map { |o| Observation.new(o) }
    end

    # What `persona` has herself noted about `about`.
    def file(persona:, about:, all: nil, limit: nil)
      @http.get("/v1/memory/file", { persona: persona, about: about, all: all, limit: limit })["observations"].map { |o| Observation.new(o) }
    end
  end

  # /v1/personas/:key/sheet: proposing is anyone's; applying is a person's.
  class Sheets
    def initialize(http)
      @http = http
    end

    def show(persona, version: nil)
      Sheet.new(@http.get("/v1/personas/#{persona}/sheet", { version: version }))
    end

    def revisions(persona, status: nil)
      @http.get("/v1/personas/#{persona}/sheet/revisions", { status: status })["revisions"].map { |r| SheetRevision.new(r) }
    end

    # ops: [{ op: add|remove|replace|set, section:, entry:?, text:? }]; citations: observation ids.
    def propose(persona, ops:, citations:, rationale: nil)
      SheetRevision.new(@http.post("/v1/personas/#{persona}/sheet/revisions", { ops: ops, citations: citations, rationale: rationale }.compact))
    end

    def apply(persona, revision_id)
      SheetRevision.new(@http.post("/v1/personas/#{persona}/sheet/revisions/#{revision_id}/apply", {})["revision"])
    end

    def reject(persona, revision_id)
      SheetRevision.new(@http.post("/v1/personas/#{persona}/sheet/revisions/#{revision_id}/reject", {})["revision"])
    end

    def rollback(persona, version:, rationale: nil)
      SheetRevision.new(@http.post("/v1/personas/#{persona}/sheet/rollback", { version: version, rationale: rationale }.compact)["revision"])
    end

    # An accretion pass: { "proposed" => [SheetRevision], "dropped" => [...], "window" => {...}, "completion" => id }
    def accrete(persona, since: nil, observations: nil, role: nil, limit: nil)
      data = @http.post("/v1/personas/#{persona}/sheet/accrete", { since: since, observations: observations, role: role, limit: limit }.compact)
      data.merge("proposed" => data["proposed"].map { |r| SheetRevision.new(r) })
    end

    # A review by the `review` model role: { "proposed" => [SheetRevision], "insights" => [...], "ruts" => [...], ... }
    def review(persona, role: nil)
      data = @http.post("/v1/personas/#{persona}/sheet/review", { role: role }.compact)
      data.merge("proposed" => data["proposed"].map { |r| SheetRevision.new(r) })
    end
  end
end
