# USD per million tokens, keyed by model id or id prefix. Config rows, not
# code: a new model's price is an insert. Prefix rows let a dated id
# ("claude-haiku-4-5-20251001") match its family row ("claude-haiku-4-5").
class ModelPrice < ApplicationRecord
  self.primary_key = :model

  validates :model, presence: true

  # Longest matching prefix wins, so a specific row beats a family row.
  def self.for_model(model)
    return nil if model.blank?

    where("? LIKE model || '%'", model).order(Arel.sql("length(model) DESC")).first
  end

  # units: { "input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens" }
  # Returns nil (not zero) when the model has no price row, so unknown cost
  # is distinguishable from free.
  def self.cost_for(model:, units:)
    for_model(model)&.cost(units)
  end

  def cost(units)
    units = units.to_h.stringify_keys
    per = ->(count, rate) { count.to_i * rate.to_d / 1_000_000 }
    (per.(units["input_tokens"], input) +
     per.(units["output_tokens"], output) +
     per.(units["cache_read_tokens"], cache_read) +
     per.(units["cache_creation_tokens"], cache_write)).round(6)
  end
end
