# A named pipeline configuration: the ordered stage list the assembly
# pipeline runs, plus provider params. This is where ST's prompt-manager
# spaghetti goes to die — presets are data, stages are code.
class Preset < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  KNOWN_STAGES = %w[persona scenario history].freeze

  # Unknown stage names are kept (forward compat) but skipped by the pipeline.
  def stage_config
    stages.presence || Assembly::Pipeline::STAGE_DEFAULTS
  end
end
