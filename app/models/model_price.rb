# USD per million tokens, keyed by model id or id prefix. Config rows, not
# code: a new model's price is an insert (PUT /v1/prices/:model,
# hob:price). Prefix rows let a dated id ("claude-haiku-4-5-20251001") match
# its family row ("claude-haiku-4-5"). Cache rates default to Anthropic's
# standard multipliers of the input rate: 0.1x read, 1.25x write.
class ModelPrice < ApplicationRecord
  self.primary_key = :model

  CACHE_READ_MULTIPLIER = 0.1
  CACHE_WRITE_MULTIPLIER = 1.25

  validates :model, presence: true, format: { with: /\A[a-z0-9][a-z0-9._@:-]*\z/i }
  validates :input, :output, :cache_read, :cache_write, numericality: { greater_than_or_equal_to: 0 }

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

  # Upsert a price. Cache rates follow the input rate unless given. With
  # `reprice` (the default) successful ledger rows for this model that had
  # no cost, or were priced by a less specific row, are recomputed; the
  # count is on `repriced`.
  def self.set!(model:, input:, output:, cache_read: nil, cache_write: nil, note: nil, effective_from: nil, reprice: true)
    row = find_or_initialize_by(model: model.to_s.strip)
    row.input = input
    row.output = output
    row.cache_read = cache_read.presence || (input.to_d * CACHE_READ_MULTIPLIER).round(4)
    row.cache_write = cache_write.presence || (input.to_d * CACHE_WRITE_MULTIPLIER).round(4)
    row.note = note if note
    row.effective_from = effective_from if effective_from
    row.save!
    row.repriced = reprice ? row.reprice! : 0
    row
  end

  attr_accessor :repriced

  # Models the ledger has seen that no row prices: what still needs a price.
  def self.unpriced_models
    UsageEvent.successful.where(cost: nil).where.not(model: [ nil, "" ]).distinct.pluck(:model)
              .reject { |m| for_model(m) }.sort
  end

  # Recompute cost for successful ledger rows this row now prices: those
  # with no cost, and those whose best price row is now this one.
  def reprice!
    count = 0
    UsageEvent.successful.where("model LIKE ?", "#{model}%").find_each do |event|
      next unless ModelPrice.for_model(event.model) == self

      fresh = cost(event.units || {})
      next if event.cost.present? && event.cost.to_d == fresh

      event.update_columns(cost: fresh)
      count += 1
    end
    count
  end

  def cost(units)
    units = units.to_h.stringify_keys
    per = ->(count, rate) { count.to_i * rate.to_d / 1_000_000 }
    (per.(units["input_tokens"], input) +
     per.(units["output_tokens"], output) +
     per.(units["cache_read_tokens"], cache_read) +
     per.(units["cache_creation_tokens"], cache_write)).round(6)
  end

  def as_json(*)
    { model: model, input: input.to_f, output: output.to_f, cache_read: cache_read.to_f, cache_write: cache_write.to_f,
      note: note, effective_from: effective_from, updated_at: updated_at }.compact
  end
end
