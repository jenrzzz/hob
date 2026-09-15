# One rule: what happens when an agent asks for a capability.
#
#   effect   allow    approve and execute
#            deny     refuse, recorded
#            review   an LLM reviewer judges it (guidance tells it how)
#            confirm  a person must approve
#
# principal NULL applies to every agent; `capability` is an exact name or a
# glob. The most specific matching rule wins (SentinelPolicy.resolve).
class SentinelPolicy < ApplicationRecord
  EFFECTS = %w[allow deny review confirm].freeze
  CONSTRAINT_KEYS = %w[in max pattern].freeze
  LIMIT_KEYS = %w[per_hour per_day cost_per_day].freeze

  belongs_to :principal, optional: true

  validates :capability, presence: true
  validates :effect, inclusion: { in: EFFECTS }
  validates :capability, uniqueness: { scope: :principal_id }
  validate :principal_is_agent
  validate :constraints_shape
  validate :limits_shape

  # The rule for (agent, capability name), or nil when nothing matches.
  # Specificity: this agent beats every agent; an exact name beats a glob
  # beats "*".
  def self.resolve(principal:, capability:)
    where(principal_id: [ principal.id, nil ]).to_a
      .select { |rule| rule.matches?(capability) }
      .max_by { |rule| [ rule.principal_id ? 1 : 0, rule.specificity ] }
  end

  def matches?(name)
    capability == "*" || capability == name || File.fnmatch?(capability, name, File::FNM_EXTGLOB)
  end

  def specificity
    return 0 if capability == "*"
    return 2 unless capability.match?(/[*?\[{]/)

    1
  end

  def for_every_agent?
    principal_id.nil?
  end

  private

  def principal_is_agent
    errors.add(:principal, "must be an agent") if principal && !principal.agent?
  end

  def constraints_shape
    return if constraints.blank?
    return errors.add(:constraints, "must be an object of argument => rule") unless constraints.is_a?(Hash)

    constraints.each do |arg, rule|
      rule = { "in" => rule } if rule.is_a?(Array)
      next errors.add(:constraints, "#{arg}: rule must be an array or object") unless rule.is_a?(Hash)

      unknown = rule.keys - CONSTRAINT_KEYS
      errors.add(:constraints, "#{arg}: unknown keys #{unknown.join(', ')}") if unknown.any?
      Regexp.new(rule["pattern"]) if rule["pattern"]
    end
  rescue RegexpError => e
    errors.add(:constraints, "bad pattern: #{e.message}")
  end

  def limits_shape
    return if limits.blank?
    return errors.add(:limits, "must be an object") unless limits.is_a?(Hash)

    unknown = limits.keys - LIMIT_KEYS
    errors.add(:limits, "unknown keys #{unknown.join(', ')}") if unknown.any?
    limits.each { |k, v| errors.add(:limits, "#{k} must be a positive number") unless v.is_a?(Numeric) && v.positive? }
  end
end
