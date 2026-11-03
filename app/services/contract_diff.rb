# Whether a capability's new input schema would break what was written
# against its old one (PLUGINS.md, section 7): callers built to the old
# shape, and SentinelPolicy constraints keyed by its argument names.
#
# Breaking: a property that is removed, a property that becomes required, a
# type that narrows (or changes), an enum that loses a value or appears
# where there was none, and an object that closes (additionalProperties
# false where it was open). Loosening goes through: a new optional
# property, a required one becoming optional, a type or an enum that
# widens. Nested object properties are compared the same way, by path.
#
# This compares shapes, not meaning: a schema that is still compatible can
# sit in front of an endpoint that now does something else (section 7).
module ContractDiff
  module_function

  # -> [String] what breaks, empty when nothing does.
  def breaking(old, new, path = "input")
    old = old.is_a?(Hash) ? old : {}
    new = new.is_a?(Hash) ? new : {}
    problems = []

    old_types = types(old)
    new_types = types(new)
    if old_types.any? && new_types.any? && narrowed?(old_types, new_types)
      problems << "#{path} was #{old_types.join(' or ')}, now #{new_types.join(' or ')}"
    end

    if new.key?("enum")
      lost = old.key?("enum") ? Array(old["enum"]) - Array(new["enum"]) : nil
      problems << "#{path} now must be one of #{Array(new['enum']).join(', ')}" if lost.nil?
      problems << "#{path} no longer accepts #{lost.map(&:inspect).join(', ')}" if lost.present?
    end

    old_props = old["properties"].is_a?(Hash) ? old["properties"] : {}
    new_props = new["properties"].is_a?(Hash) ? new["properties"] : {}
    (old_props.keys - new_props.keys).each { |name| problems << "#{path}.#{name} was removed" }
    (Array(new["required"]) - Array(old["required"])).each { |name| problems << "#{path}.#{name} is now required" }
    if new["additionalProperties"] == false && old["additionalProperties"] != false && (old_types.include?("object") || old_props.any?)
      problems << "#{path} no longer takes properties it does not name"
    end

    (old_props.keys & new_props.keys).each do |name|
      problems.concat(breaking(old_props[name], new_props[name], "#{path}.#{name}"))
    end
    problems
  end

  # An integer is a number: integer -> number widens.
  def narrowed?(old_types, new_types)
    old_types.any? { |type| !new_types.include?(type) && !(type == "integer" && new_types.include?("number")) }
  end

  def types(schema)
    Array(schema["type"]).map(&:to_s)
  end
end
