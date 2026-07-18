class Principal < ApplicationRecord
  KINDS = %w[human persona worker surface].freeze

  has_many :api_keys, dependent: :destroy

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, uniqueness: true
  validates :max_clearance, presence: true
end
