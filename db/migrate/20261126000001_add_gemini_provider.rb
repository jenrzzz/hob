# Google's Gemini, spoken to natively (Provider::KINDS). GCLOUD_API_KEY is a
# Vertex AI express-mode key, which the Gemini Developer API refuses, so the
# row points at Vertex's publisher endpoint (same generateContent). Existing
# installations never run seeds again: give them the provider row and the
# list prices (USD per million tokens, as ruby_llm 2.0's registry has them).
# A role on it is still a config row: hob:role[name,gemini,<model>].
class AddGeminiProvider < ActiveRecord::Migration[8.1]
  # model => [input, output, cache_read]
  PRICES = {
    "gemini-3.8-flash"      => [ 0.75, 3.75, 0.075 ],
    "gemini-3.7-flash"      => [ 0.75, 3.75, 0.075 ],
    "gemini-3.6-flash"      => [ 0.75, 3.75, 0.075 ],
    "gemini-3.5-flash"      => [ 1.50, 9.00, 0.15 ],
    "gemini-3.5-flash-lite" => [ 0.30, 2.50, 0.03 ],
    "gemini-3.1-pro"        => [ 2.00, 12.00, 0.20 ],
    "gemini-3.1-flash-lite" => [ 0.25, 1.50, 0.025 ],
    "gemini-3-flash"        => [ 0.50, 3.00, 0.05 ]
  }.freeze

  def up
    now = connection.quote(Time.current)
    execute <<~SQL
      INSERT INTO providers (slug, kind, config, created_at, updated_at)
      VALUES ('gemini', 'gemini', '{"api_key_env":"GCLOUD_API_KEY","base_url":"https://aiplatform.googleapis.com/v1/publishers/google"}', #{now}, #{now})
      ON CONFLICT (slug) DO NOTHING
    SQL
    PRICES.each do |model, (input, output, cache_read)|
      # Gemini's caching is implicit and has no write charge; the rate is
      # here only because the column wants one.
      execute <<~SQL
        INSERT INTO model_prices (model, input, output, cache_read, cache_write, note, created_at, updated_at)
        VALUES (#{connection.quote(model)}, #{input}, #{output}, #{cache_read}, #{input}, 'seed', #{now}, #{now})
        ON CONFLICT (model) DO NOTHING
      SQL
    end
  end

  def down
    execute "DELETE FROM providers WHERE slug = 'gemini'"
  end
end
