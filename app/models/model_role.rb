class ModelRole < ApplicationRecord
  validates :role, presence: true, uniqueness: true
  validates :chain, presence: true

  Resolution = Struct.new(:provider, :model, :params, keyword_init: true)

  # Walk the fallback chain and return the first link whose provider is
  # configured and (for transient providers) currently online.
  def resolve
    chain.each do |link|
      provider = Provider.find_by(slug: link["provider"])
      next unless provider&.available?

      return Resolution.new(provider: provider, model: link["model"], params: link["params"] || {})
    end
    raise Gateway::NoProviderError, "no available provider for role #{role.inspect}"
  end

  def self.resolve!(role)
    find_by(role: role.to_s)&.resolve ||
      raise(Gateway::UnknownRoleError, "unknown model role #{role.inspect}")
  end
end
