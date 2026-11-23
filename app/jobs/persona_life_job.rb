# A persona's life, on the clock (MELUZINA.md, "A persona's life"). Every 15
# minutes each living persona rolls her hour's odds; past her minimum gap, a
# hit runs one beat. With odds weighted toward her own hours that lands a
# few beats a day, when she would be up.
#
# The same clock folds her home conversation into her memory once a stretch
# of it has left living presence (PersonaLife::Fold): one stretch a tick.
class PersonaLifeJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "persona_life"

  def perform(now: Time.current, force: nil)
    PersonaLife.living.find_each do |persona|
      life = PersonaLife.new(persona)
      # At the highest realm the life is kept at: an elevated lane's beat
      # counts toward the gap.
      due = Clearance.with(life.top_realm) { force == persona.key || life.due?(now: now) }
      life.beat!(now: now) if due
    rescue StandardError => e
      Rails.logger.error("persona life #{persona.key}: #{e.class}: #{e.message}")
    ensure
      # At most once an hour: a fold is never urgent (it reads from the
      # conversation itself, so nothing is lost by waiting), and one that
      # keeps failing must not ask a model every fifteen minutes.
      fold(persona, now) if now.min < 15
    end
  end

  private

  # A fold that fails costs the fold, never the beat or the next persona.
  def fold(persona, now)
    fold = PersonaLife::Fold.new(PersonaLife.new(persona), now: now)
    fold.run! if fold.due?
  rescue StandardError => e
    Rails.logger.error("persona fold #{persona.key}: #{e.class}: #{e.message}")
  end
end
