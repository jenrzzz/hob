module Gateway
  # A client-session tool as the caller declares it: { name, description,
  # input_schema }. Duck-typed to what ruby_llm's provider renderers read
  # off a RubyLLM::Tool (name, description, params_schema, parameters,
  # provider_params) so hob never has to define a Tool class per request.
  class ToolDef < Struct.new(:name, :description, :input_schema, keyword_init: true)
    NAME_FORMAT = /\A[a-zA-Z0-9_-]{1,64}\z/
    CHOICES = %w[auto none required].freeze

    def self.normalize(tools)
      Array(tools).map do |raw|
        t = raw.to_h.stringify_keys
        name = t["name"].to_s
        raise Invalid, "tool name #{name.inspect} must match #{NAME_FORMAT.inspect}" unless name.match?(NAME_FORMAT)

        schema = t["input_schema"] || t["parameters"] || { "type" => "object", "properties" => {} }
        raise Invalid, "tool #{name}: input_schema must be an object" unless schema.is_a?(Hash)

        new(name: name, description: t["description"].to_s, input_schema: schema.deep_stringify_keys)
      end.tap { |defs| raise Invalid, "duplicate tool names" if defs.map(&:name).uniq.size != defs.size }
    end

    # auto (nil) | none | required | a declared tool's name
    def self.normalize_choice(choice, tools)
      return nil if choice.blank? || choice.to_s == "auto"

      choice = choice.to_s
      return choice if CHOICES.include?(choice) || tools.any? { |t| t.name == choice }

      raise Invalid, "tool_choice #{choice.inspect} is not auto, none, required, or a declared tool"
    end

    def params_schema = input_schema
    def parameters = {}
    def provider_params = {}

    def to_h
      { "name" => name, "description" => description, "input_schema" => input_schema }
    end
  end
end
