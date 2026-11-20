# A persona's life, on the clock (MELUZINA.md, "A persona's life"). Every 15
# minutes each living persona rolls her hour's odds; past her minimum gap, a
# hit runs one beat. With odds weighted toward her own hours that lands a
# few beats a day, when she would be up.
class PersonaLifeJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "persona_life"

  def perform(now: Time.current, force: nil)
    PersonaLife.living.find_each do |persona|
      life = PersonaLife.new(persona)
      due = Clearance.with(life.realm) { force == persona.key || life.due?(now: now) }
      life.beat!(now: now) if due
    rescue StandardError => e
      Rails.logger.error("persona life #{persona.key}: #{e.class}: #{e.message}")
    end
  end
end
