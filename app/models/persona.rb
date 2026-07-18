class Persona < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  before_create { self.id ||= ULID.generate }

  # prompt keys: system_core (required), greetings [], examples []
  def system_core
    prompt["system_core"].to_s
  end
end
