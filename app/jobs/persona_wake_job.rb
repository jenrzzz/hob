# A beat of a persona's life soon after her agent was spoken to on hob's
# IRC (PersonaLife::Wake, IRC.md, "Woken"). Queued by the line that named
# her; it runs her one pending wake, waits out her gap, or drops it. It
# never runs beside another beat of hers (PersonaLife#exclusively).
class PersonaWakeJob < ApplicationJob
  queue_as :default

  def perform(persona_id)
    persona = Persona.find_by(id: persona_id) or return
    PersonaLife::Wake.new(PersonaLife.new(persona)).run!
  rescue StandardError => e
    Rails.logger.error("persona wake #{persona_id}: #{e.class}: #{e.message}")
  end
end
