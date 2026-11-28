module Memory
  # Embeddings for observations through the `embedding` model role
  # (MEMORY.md, "Embeddings"). Optional: with no such role, or with its
  # provider away, observations are kept without a vector and recall leans on
  # entities, words, and recency until `hob:memory:embed` fills them in.
  # Vectors are compared only within one model (`embedding_model`), so a
  # model swap is a re-embed, never a mixed comparison.
  module Embedder
    ROLE = "embedding".freeze

    module_function

    def available?
      ModelRole.exists?(role: ROLE)
    end

    # Embeds what has no vector yet; failures leave them unembedded.
    def embed!(observations)
      todo = Array(observations).select { |o| o.embedding.nil? }
      return [] if todo.empty? || !available?

      todo.each_slice(64).flat_map do |slice|
        vectors, model = Gateway.embed(role: ROLE, texts: slice.map(&:body), operation: "memory.embed")
        slice.zip(vectors).each do |o, vector|
          o.update_columns(embedding: literal(vector), embedding_model: model)
        end
        slice
      end
    rescue Gateway::Error => e
      Rails.error.report(e, handled: true, severity: :warning, source: "hob.memory.embed")
      []
    end

    # -> [vector literal, model] or nil when embeddings are off or failing.
    def query(text)
      return nil unless available?

      vectors, model = Gateway.embed(role: ROLE, texts: [ text.to_s ], operation: "memory.recall")
      [ literal(vectors.first), model ]
    rescue Gateway::Error => e
      Rails.error.report(e, handled: true, severity: :warning, source: "hob.memory.embed")
      nil
    end

    # The rows of `relation` nearest `vector` by cosine, nearest first.
    # -> [[row, similarity]]
    #
    # warp (0..1, Dose) makes the search overshoot. Of n rows it skips the
    # nearest n**warp - 1 and returns the ones after them, scored as though
    # they were the nearest: a little warp lands a few neighbours out, a lot
    # lands among things that have nothing to do with the query. Counted in
    # neighbours, not in similarity, so it means the same in a memory of
    # fifty notes, an archive of fifty thousand, and under any model.
    def nearest(relation, column:, vector:, limit:, warp: 0.0)
      distance = relation.klass.sanitize_sql_array([ "(#{column} <=> ?::vector)", vector ])
      ranked = relation.select("#{relation.klass.table_name}.*, #{distance} AS distance").order(Arel.sql("distance ASC"))
      skip = overshoot(relation, warp)
      rows = ranked.offset(skip).limit(limit).to_a
      return [] if rows.empty?

      shift = skip.zero? ? 0.0 : rows.first.attributes["distance"].to_f - ranked.limit(1).to_a.first.attributes["distance"].to_f
      rows.map { |row| [ row, 1.0 - (row.attributes["distance"].to_f - shift) ] }
    end

    def overshoot(relation, warp)
      return 0 unless warp.to_f.positive?

      count = relation.count
      count < 2 ? 0 : ((count**warp.to_f) - 1).round.clamp(0, count - 1)
    end

    def literal(vector)
      "[#{Array(vector).map { |x| Float(x).to_s }.join(',')}]"
    end
  end
end
