# The memory plane, v1 (MEMORY.md): entities, observations about them, and
# hybrid recall. Every read runs under the request's RLS clearance, so a
# lower-clearance caller structurally cannot see a higher-realm observation;
# every write is stamped with its provenance from the request, never from the
# arguments.
#
# Writes land at one realm, chosen by the caller of these methods, never by
# the model: the request's clearance for a surface's deposit, the
# conversation's taint for a persona's `remember` (Memory::Tools). Nothing
# here moves an observation between realms.
module Memory
  class NotFound < Gateway::Invalid; end

  DEPOSIT_LIMIT = 500
  RECALL_LIMIT = 20
  RECALL_BUDGET = 2_000 # characters of rendered lines
  CANDIDATES = 100
  # A vector neighbour below this cosine similarity is noise, not memory.
  MIN_SIMILARITY = 0.2
  RECENCY_HALF_LIFE_DAYS = 30.0
  ULID_FORMAT = /\A[0-9A-HJKMNP-TV-Z]{26}\z/

  module_function

  # --- entities ----------------------------------------------------------

  # spec: an entity id, a ref ("principal:jenner"), a unique name or alias,
  # or { type, name, ref?, aliases? } (made when create: true and not found).
  def entity(spec, create: false)
    case spec
    when Entity then spec
    when Hash, ActionController::Parameters
      spec = spec.to_h.stringify_keys
      found = spec["id"].presence && Entity.find_by(id: spec["id"])
      found ||= spec["ref"].presence && Entity.find_by(ref: spec["ref"])
      return found if found
      raise NotFound, "no entity #{spec.slice('id', 'ref', 'name').compact.to_json}" unless create

      Entity.create!(kind: spec["type"] || spec["kind"], name: spec["name"], ref: spec["ref"],
                     aliases: Array(spec["aliases"]).map(&:to_s), created_by: Current.principal&.name)
    when String
      spec = spec.strip
      return Entity.find_by(id: spec) || raise(NotFound, "no entity #{spec}") if spec.match?(ULID_FORMAT)
      if spec.match?(Entity::REF_FORMAT)
        found = Entity.find_by(ref: spec) || principal_entity(spec)
        return found if found

        raise NotFound, "no entity with ref #{spec}"
      end

      matches = Entity.where("lower(name) = lower(?) OR ? = ANY(aliases)", spec, spec).limit(2).to_a
      raise NotFound, "no entity named #{spec.inspect}" if matches.empty?
      raise Gateway::Invalid, "#{spec.inspect} names more than one entity; use its id or ref" if matches.size > 1

      matches.first
    else
      raise Gateway::Invalid, "an entity is an id, a ref, a name, or { type, name, ref }"
    end
  end

  # "principal:<name>" and "persona:<key>" resolve even before anything has
  # been said about them.
  def principal_entity(ref)
    kind, name = ref.split(":", 2)
    case kind
    when "principal" then (p = Principal.find_by(name: name)) && Entity.for_principal(p)
    when "persona" then Persona.find_by(key: name)&.memory_entity
    end
  end

  # --- writes ------------------------------------------------------------

  # One observation. `realm` is decided by the caller (see the module note);
  # `author` is a persona's entity when she is the one noticing.
  def remember!(about:, body:, realm:, kind: "note", author: nil, evidence: [], observed_at: nil,
                conversation: nil, node: nil, source: {}, embed: true)
    write_check!(realm)
    observation = Observation.create!(
      entity: entity(about, create: about.is_a?(Hash)), author_entity: author, kind: kind.presence || "note",
      body: body.to_s.strip, realm: realm, principal: Current.principal, surface: Current.surface || "hob",
      conversation_id: conversation&.id, node_hash: node, evidence: Array(evidence).map(&:to_s),
      source: source.to_h.compact, observed_at: observed_at.presence || Time.current, created_at: Time.current
    )
    Embedder.embed!([ observation ]) if embed
    observation
  end

  # Many, all or nothing (a surface's bulk deposit). items: [{ about, body,
  # kind?, persona?, evidence?, observed_at?, source? }]
  def deposit!(items, realm:)
    items = Array(items)
    raise Gateway::Invalid, "observations: give 1 to #{DEPOSIT_LIMIT}" if items.empty? || items.size > DEPOSIT_LIMIT

    written = Observation.transaction do
      items.each_with_index.map do |raw, index|
        item = raw.to_h.deep_stringify_keys
        unknown = item.keys - %w[about body kind persona evidence observed_at source]
        raise Gateway::Invalid, "observation #{index}: unknown field #{unknown.join(', ')}" if unknown.any?

        author = item["persona"].presence && Persona.find_by!(key: item["persona"]).memory_entity
        remember!(about: item["about"], body: item["body"], kind: item["kind"], author: author, realm: realm,
                  evidence: item["evidence"], observed_at: item["observed_at"],
                  source: (item["source"] || {}).slice("ref", "note"), embed: false)
      rescue ActiveRecord::RecordInvalid, Gateway::Invalid, ActiveRecord::RecordNotFound => e
        raise Gateway::Invalid, "observation #{index}: #{e.message}"
      end
    end
    Embedder.embed!(written)
    written
  end

  # A correction: a new observation that takes the old one's place. Only at
  # the old one's own realm — retiring a household fact from an intimate
  # request would tell household readers something (MEMORY.md, "Realms").
  def supersede!(old, body:, realm:, kind: nil, evidence: nil, reason: nil, author: :same)
    same_realm!(old, realm)
    raise Gateway::Invalid, "observation #{old.id} is #{old.status}; supersede the current one" unless old.current?

    Observation.transaction do
      replacement = remember!(
        about: old.entity, body: body, kind: kind || old.kind, realm: realm,
        author: author == :same ? old.author_entity : author, evidence: evidence || old.evidence,
        source: { "reason" => reason }.compact, embed: false
      )
      replacement.update_columns(supersedes_id: old.id)
      old.update!(superseded_by_id: replacement.id, retire_reason: reason)
      Embedder.embed!([ replacement ])
      replacement
    end
  end

  # by: who retired it, when it was not the request's principal (a persona
  # letting go of a note of her own: "persona:<key>").
  def retire!(old, reason:, realm:, by: nil)
    same_realm!(old, realm)
    raise Gateway::Invalid, "observation #{old.id} is #{old.status}" unless old.current?
    raise Gateway::Invalid, "a retirement needs a reason" if reason.blank?

    old.update!(retired_at: Time.current, retired_by: by.presence || Current.principal&.name || Current.surface, retire_reason: reason)
    old
  end

  # Every version in the chain this observation belongs to, oldest first, as
  # far as this clearance can see (they share a realm, so all of it).
  def history(observation)
    chain = [ observation ]
    while (prev = chain.first.supersedes_id && Observation.find_by(id: chain.first.supersedes_id))
      chain.unshift(prev)
    end
    while (nxt = chain.last.superseded_by_id && Observation.find_by(id: chain.last.superseded_by_id))
      chain << nxt
    end
    chain
  end

  # --- reads -------------------------------------------------------------

  # "Her file on him": what persona P has herself noticed or decided about
  # entity E, newest first, current only unless all: true.
  def file(persona:, about:, limit: 100, all: false)
    scope = Observation.where(author_entity_id: persona.memory_entity.id, entity_id: entity(about).id)
    scope = scope.current unless all
    scope.order(observed_at: :desc).limit(limit.to_i.clamp(1, 500)).to_a
  end

  Hit = Struct.new(:observation, :score, :reasons, keyword_init: true)

  # Hybrid recall: candidates by entity, by keyword, and by embedding
  # similarity, scored together with recency, then cut to a budget. Every
  # candidate query runs under RLS, so the realm filter is inside the query.
  #
  # about:  entities (ids/refs/names) the caller is asking about
  # author: a persona's entity; scope "mine" keeps only what she authored
  # budget: characters of rendered lines (Memory.line) to return at most
  # warp:   0..1, how far a dose has her recall off true (Dose): the
  #         neighbours overshoot (Embedder.nearest) and her words hold less
  def recall(query: nil, about: [], author: nil, scope: "all", limit: RECALL_LIMIT, budget: RECALL_BUDGET, now: Time.current,
             warp: 0.0)
    raise Gateway::Invalid, "scope is all or mine" unless %w[all mine].include?(scope.to_s)
    raise Gateway::Invalid, "scope mine needs a persona" if scope.to_s == "mine" && author.nil?

    about_ids = Array(about).compact_blank.map { |spec| entity(spec).id }
    base = Observation.current
    base = base.where(author_entity_id: author.id) if scope.to_s == "mine"
    hits = Hash.new { |h, id| h[id] = { sim: 0.0, kw: 0.0, about: 0.0, reasons: [] } }
    rows = {}

    if about_ids.any?
      base.where(entity_id: about_ids).order(observed_at: :desc).limit(CANDIDATES).each do |o|
        rows[o.id] = o
        hits[o.id][:about] = 1.0
        hits[o.id][:reasons] << "about"
      end
    end

    if (tsquery = tsquery_for(query))
      ranked = base.where("document @@ to_tsquery('english', ?)", tsquery)
                   .select(Observation.sanitize_sql_array([ "observations.*, ts_rank(document, to_tsquery('english', ?)) AS kw_rank", tsquery ]))
                   .order(Arel.sql("kw_rank DESC")).limit(CANDIDATES).to_a
      top = ranked.map { |o| o.attributes["kw_rank"].to_f }.max.to_f
      ranked.each do |o|
        rows[o.id] = o
        hits[o.id][:kw] = top.positive? ? o.attributes["kw_rank"].to_f / top : 0.0
        hits[o.id][:reasons] << "words"
      end
    end

    if query.present? && (embedded = Embedder.query(query))
      vector, model = embedded
      near = base.where(embedding_model: model).where.not(embedding: nil)
      Embedder.nearest(near, column: "observations.embedding", vector: vector, limit: CANDIDATES, warp: warp).each do |o, similarity|
        next if similarity < MIN_SIMILARITY && !rows.key?(o.id)

        rows[o.id] = o
        hits[o.id][:sim] = [ similarity, 0.0 ].max
        hits[o.id][:reasons] << "similar"
      end
    end

    if about_ids.empty? && query.blank?
      base.order(observed_at: :desc).limit(CANDIDATES).each do |o|
        rows[o.id] = o
        hits[o.id][:reasons] << "recent"
      end
    end

    scored = rows.values.map do |o|
      h = hits[o.id]
      age_days = [ (now - o.observed_at) / 1.day, 0 ].max
      recency = 0.5**(age_days / RECENCY_HALF_LIFE_DAYS)
      score = (0.45 * h[:sim]) + (0.25 * (1.0 - warp.to_f) * h[:kw]) + (0.2 * h[:about]) + (0.1 * recency)
      Hit.new(observation: o, score: score.round(4), reasons: h[:reasons].uniq)
    end
    scored.sort_by! { |hit| [ -hit.score, -hit.observation.observed_at.to_f ] }

    spent = 0
    kept = []
    scored.first(limit.to_i.clamp(1, 200)).each do |hit|
      cost = line(hit.observation, now: now).length + 1
      break if budget && spent + cost > budget.to_i && kept.any?

      spent += cost
      kept << hit
    end
    ActiveRecord::Associations::Preloader.new(records: kept.map(&:observation), associations: %i[entity author_entity]).call
    kept
  end

  # One line per observation, the shape the recall stage and tool render.
  def line(observation, now: Time.current)
    about = observation.entity&.name || observation.entity_id
    by = observation.author_entity ? "#{observation.author_entity.name} noted" : observation.surface
    age = age_words(now - observation.observed_at)
    "- [#{observation.id}] about #{about} (#{observation.kind}; #{by}, #{age}): #{observation.body.squish}"
  end

  def age_words(seconds)
    days = (seconds / 1.day).floor
    return "today" if days < 1
    return "#{days}d ago" if days < 60

    "#{(days / 30.4).round}mo ago"
  end

  # OR of prefix terms from the query's words: forgiving, and safe (the
  # words are letters and digits only, and the string is bound).
  def tsquery_for(query)
    words = query.to_s.downcase.scan(/[[:alnum:]]{2,}/).uniq.first(24)
    return nil if words.empty?

    words.map { |w| "#{w}:*" }.join(" | ")
  end

  def write_check!(realm)
    rank = Realm.rank_of(realm)
    raise Gateway::Invalid, "cannot write memory above this request's clearance" if Clearance.current && rank > Realm.rank_of(Clearance.current)
  end

  def same_realm!(observation, realm)
    return if observation.realm == realm

    raise Gateway::Invalid, "observation #{observation.id} is #{observation.realm}; correct it at that realm " \
                            "(this request writes at #{realm}; X-Hob-Clearance can lower it)"
  end
end
