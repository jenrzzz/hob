# Something the household's memory is about (MEMORY.md): a person, a persona,
# a media item, a place, a topic. Global and realm-less on purpose: an entity
# is a name and a type, and everything said *about* it is an Observation,
# which carries a realm. Types are free-form strings with a small blessed
# core; a `ref` names the thing elsewhere ("principal:jenner",
# "persona:meluzina", "kat:media:30880") and is how surfaces address it.
class Entity < ApplicationRecord
  BLESSED_KINDS = %w[person persona work event place preference topic].freeze
  REF_FORMAT = /\A[a-z][a-z0-9_-]*:\S+\z/
  KIND_FORMAT = /\A[a-z][a-z0-9_.-]{0,63}\z/

  has_many :observations, dependent: :restrict_with_exception
  has_one :persona, dependent: :restrict_with_exception

  validates :kind, format: { with: KIND_FORMAT, message: "is a lowercase word (person, persona, work, ...)" }
  validates :name, presence: true, length: { maximum: 200 }
  validates :ref, format: { with: REF_FORMAT, message: "is <kind>:<id>" }, uniqueness: true, allow_nil: true

  before_create { self.id ||= ULID.generate }
  normalizes :ref, with: ->(ref) { ref.to_s.strip.presence }

  # The entity a household principal is: one per principal, made on first use.
  def self.for_principal(principal)
    find_or_create_by!(ref: "principal:#{principal.name}") do |e|
      e.kind = principal.kind == "human" ? "person" : principal.kind
      e.name = principal.name
      e.created_by = "hob"
    end
  end

  def as_json(*)
    { id: id, type: kind, name: name, aliases: aliases, ref: ref, created_at: created_at }
  end
end
