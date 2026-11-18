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

    def literal(vector)
      "[#{Array(vector).map { |x| Float(x).to_s }.join(',')}]"
    end
  end
end
