# Console sessions are short (KVM.md): ttl seconds without a step, and half
# an hour at most. The bridge ends idle ones itself; this ends the rows, and
# any session the bridge still holds, so the KVM goes back to its owner and
# console.sessions says what is really open. Full clearance: every realm.
class ConsoleSweepJob < ApplicationJob
  queue_as :default

  def perform
    Clearance.with("intimate") do
      Current.set(surface: "console-sweep") { Consoles.sweep! }
    end
  end
end
