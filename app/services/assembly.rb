module Assembly
  # ~4 chars/token is close enough for budgeting; exact counts come from the
  # provider's usage block after the fact.
  def self.estimate_tokens(text)
    (text.to_s.length / 4.0).ceil
  end
end
