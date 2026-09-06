class ModelRole < ApplicationRecord
  validates :role, presence: true, uniqueness: true
  validates :chain, presence: true

  # One link of the chain, resolved. `strict` links (A7) fail the request
  # instead of falling through when their provider is unavailable.
  Resolution = Struct.new(:provider, :model, :params, :strict, keyword_init: true) do
    def strict?
      !!strict
    end
  end

  # Every link whose provider is configured, in chain order. A strict link
  # with no configured provider raises rather than being skipped.
  def candidates
    chain.filter_map do |link|
      provider = Provider.find_by(slug: link["provider"])
      resolution = Resolution.new(provider: provider, model: link["model"],
                                  params: link["params"] || {}, strict: link["strict"])
      next resolution if provider&.available?
      next nil unless resolution.strict?

      raise Gateway::NoProviderError,
            "strict link #{link['provider']}/#{link['model']} for role #{role.inspect} is unavailable"
    end
  end

  # The link a call would start with.
  def resolve
    candidates.first || raise(Gateway::NoProviderError, "no available provider for role #{role.inspect}")
  end

  def self.find_role!(role)
    find_by(role: role.to_s) || raise(Gateway::UnknownRoleError, "unknown model role #{role.inspect}")
  end

  def self.resolve!(role)
    find_role!(role).resolve
  end
end
