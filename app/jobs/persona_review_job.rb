# The long look, on a clock (MEMORY.md, "Review"). A persona opts in with
# memory: { review: { every_days: 7, realm: "intimate" } }; each morning this
# reviews the ones that are due, at the realm they asked for. Everything a
# review writes is proposed or an observation, so nothing here needs a person
# present; a person still applies what it proposes.
class PersonaReviewJob < ApplicationJob
  queue_as :default

  DEFAULT_DAYS = 7

  def perform(now: Time.current)
    return unless ModelRole.exists?(role: PersonaSheet::Review::ROLE)

    Persona.where("memory ? 'review'").find_each do |persona|
      config = persona.memory["review"]
      next unless config.is_a?(Hash)

      Clearance.with(config["realm"].presence || "household") do
        Current.set(surface: "review") do
          last = PersonaSheet::Review.last_at(persona)
          days = config["every_days"].to_i.clamp(1, 365)
          days = DEFAULT_DAYS if config["every_days"].blank?
          next if last && last > now - days.days

          PersonaSheet::Review.new(persona).call
        end
      end
    rescue StandardError => e
      Rails.logger.error("persona review #{persona.key}: #{e.class}: #{e.message}")
    end
  end
end
