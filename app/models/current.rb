class Current < ActiveSupport::CurrentAttributes
  attribute :principal, :api_key, :clearance, :surface
  # What a persona's beat may still say on IRC (PersonaLife::Visit::Allowance); nil is no limit.
  attribute :irc_lines
end
