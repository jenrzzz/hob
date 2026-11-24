class Current < ActiveSupport::CurrentAttributes
  attribute :principal, :api_key, :clearance, :surface
  # What a persona's beat may still say on IRC (PersonaLife::Visit::Allowance); nil is no limit.
  attribute :irc_lines
  # A line on IRC woke this beat (PersonaLife::Wake): what it says is not company (Irc::Company).
  attribute :woken
end
