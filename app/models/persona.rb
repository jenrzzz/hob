class Persona < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :name, presence: true
  validate :clock_reads, :tools_read, :life_reads

  belongs_to :entity, optional: true
  has_many :sheet_revisions, class_name: "PersonaSheetRevision", dependent: :restrict_with_exception

  before_create { self.id ||= ULID.generate }

  MEMORY_OPTIONS = %w[recall tools budget about own].freeze

  # The entity this persona *is* (DESIGN.md: "memory scope"), made on first
  # use: what she notices and decides are observations she authors.
  def memory_entity
    return entity if entity

    made = Entity.find_or_create_by!(ref: "persona:#{key}") { |e| e.kind = "persona"; e.name = name; e.created_by = "hob" }
    update!(entity: made)
    made
  end

  # The persona's default memory options; a request's `memory:` overrides.
  def memory_options
    (memory || {}).slice(*MEMORY_OPTIONS)
  end

  # prompt keys: system_core (required), greetings [], examples [],
  # instruction (optional trailing user-turn text, B3)
  def system_core
    prompt["system_core"].to_s
  end

  def instruction
    prompt["instruction"].presence
  end

  # ST card v2/v3 (or bare v1 fields) -> native persona. {{char}} resolves at
  # import; {{user}} stays for the assembly pipeline to resolve per-request.
  def self.from_card!(card, key: nil)
    data = card["data"] || card
    name = data["name"].to_s.strip
    raise ArgumentError, "card has no name" if name.blank?

    fill = ->(text) { text.to_s.gsub(/{{char}}/i, name).strip }

    system_core = [
      fill.(data["description"]),
      data["personality"].present? ? "Personality: #{fill.(data['personality'])}" : nil,
      data["scenario"].present? ? "Scenario: #{fill.(data['scenario'])}" : nil
    ].compact.reject(&:empty?).join("\n\n")

    greetings = [ data["first_mes"], *Array(data["alternate_greetings"]) ]
                .filter_map { |g| fill.(g).presence }
    examples = [ fill.(data["mes_example"]).presence ].compact

    create!(
      key: key || name.parameterize,
      name: name,
      prompt: { "system_core" => system_core, "greetings" => greetings, "examples" => examples },
      card_import: card
    )
  end

  private

  def tools_read
    (CorpusTools.problems(tools || {}) + AgentTools.problems(tools || {})).each { |problem| errors.add(:tools, problem) }
  end

  def life_reads
    PersonaLife.problems(life || {}).each { |problem| errors.add(:life, problem) }
  end

  def clock_reads
    Assembly::Clock.for(self)
  rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier => e
    errors.add(:clock, e.message)
  end
end
