class Persona < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  before_create { self.id ||= ULID.generate }

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
end
