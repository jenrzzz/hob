module Records
  # Searching a collection by meaning (MELUZINA.md, "Searchable
  # collections"). A collection with `embed_path` has that top-level field of
  # each record embedded through the `embedding` role, the way observations
  # are (Memory::Embedder): optional, compared only within one model, filled
  # in later by `hob:records:embed` when the role is away. Search ranks by
  # similarity and the record's existing `tsvector`, under RLS like every
  # other read, so a collection above the caller's clearance is not found.
  module Search
    CANDIDATES = 100
    # A neighbour below this is noise (Memory::MIN_SIMILARITY's reasoning).
    MIN_SIMILARITY = 0.2
    EMBED_BATCH = 64
    DEFAULT_LIMIT = 5
    MAX_LIMIT = 20

    Hit = Struct.new(:record, :score, :reasons, keyword_init: true)

    module_function

    # -> [Hit], best first. With no query, `sample` instead.
    def search(collection, query:, limit: DEFAULT_LIMIT)
      limit = limit.to_i.clamp(1, MAX_LIMIT)
      base = collection.records.live
      rows = {}
      hits = Hash.new { |h, id| h[id] = { sim: 0.0, kw: 0.0, reasons: [] } }

      if (tsquery = Memory.tsquery_for(query))
        ranked = base.where("records.document @@ to_tsquery('simple', ?)", tsquery)
                     .select(Record.sanitize_sql_array([ "records.*, ts_rank(records.document, to_tsquery('simple', ?)) AS kw_rank", tsquery ]))
                     .order(Arel.sql("kw_rank DESC")).limit(CANDIDATES).to_a
        top = ranked.map { |r| r.attributes["kw_rank"].to_f }.max.to_f
        ranked.each do |r|
          rows[r.id] = r
          hits[r.id][:kw] = top.positive? ? r.attributes["kw_rank"].to_f / top : 0.0
          hits[r.id][:reasons] << "words"
        end
      end

      if collection.embed_path && (embedded = Memory::Embedder.query(query))
        vector, model = embedded
        base.where(embedding_model: model).where.not(embedding: nil)
            .select(Record.sanitize_sql_array([ "records.*, (records.embedding <=> ?::vector) AS distance", vector ]))
            .order(Arel.sql("distance ASC")).limit(CANDIDATES).each do |r|
          similarity = 1.0 - r.attributes["distance"].to_f
          next if similarity < MIN_SIMILARITY

          rows[r.id] = r
          hits[r.id][:sim] = similarity
          hits[r.id][:reasons] << "similar"
        end
      end

      rows.values.map { |r| Hit.new(record: r, score: (0.65 * hits[r.id][:sim] + 0.35 * hits[r.id][:kw]).round(4),
                                    reasons: hits[r.id][:reasons]) }
          .sort_by { |hit| [ -hit.score, hit.record.key ] }
          .first(limit)
    end

    # Records chosen without a query: at random, preferring those observed in
    # this month of any year when there are some ("remember this season").
    def sample(collection, limit: 1, now: Time.current)
      limit = limit.to_i.clamp(1, MAX_LIMIT)
      base = collection.records.live
      season = base.where("EXTRACT(MONTH FROM records.observed_at) = ?", now.month)
      pool = season.exists? ? season : base
      pool.order(Arel.sql("RANDOM()")).limit(limit).map { |r| Hit.new(record: r, score: 0.0, reasons: [ "unasked" ]) }
    end

    # The text a record is embedded by: its collection's embed_path field.
    def text_of(record, collection = record.collection)
      value = record.data[collection.embed_path]
      value.is_a?(String) ? value : value&.to_json
    end

    # Embeds what has no vector yet in collections that embed; failures
    # leave them for later. -> how many were embedded.
    def embed!(records)
      todo = Array(records).select { |r| r.embedding.nil? && r.collection.embed_path && text_of(r).present? }
      return 0 if todo.empty? || !Memory::Embedder.available?

      todo.each_slice(EMBED_BATCH).sum do |slice|
        vectors, model = Gateway.embed(role: Memory::Embedder::ROLE, texts: slice.map { |r| text_of(r) },
                                       operation: "records.embed")
        slice.zip(vectors).each { |r, v| r.update_columns(embedding: Memory::Embedder.literal(v), embedding_model: model) }
        slice.size
      end
    rescue Gateway::Error => e
      Rails.error.report(e, handled: true, severity: :warning, source: "hob.records.embed")
      0
    end

    # Everything in a collection still waiting for a vector, in batches.
    def backfill!(collection)
      return 0 unless collection.embed_path

      total = 0
      collection.records.live.where(embedding: nil).in_batches(of: EMBED_BATCH * 4) do |batch|
        done = embed!(batch.includes(:collection).to_a)
        break if done.zero?

        total += done
      end
      total
    end
  end
end
