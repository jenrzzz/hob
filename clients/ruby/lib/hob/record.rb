module Hob
  # A thin reader over one of hob's JSON objects: string-keyed data, explicit
  # accessors, no surprises.
  class Record
    def self.attribute(*names)
      names.each do |name|
        define_method(name) { @data[name.to_s] }
      end
    end

    attr_reader :data

    def initialize(data)
      @data = (data || {}).to_h.transform_keys(&:to_s)
    end

    def [](key)
      @data[key.to_s]
    end

    def to_h
      @data
    end

    def inspect
      "#<#{self.class.name} #{@data.inspect}>"
    end
  end

  # An event off an SSE stream: { type: delta|retry|tool_call|usage|done|error, ... }.
  class Event < Record
    attribute :type, :content, :reason, :status, :message

    def delta?
      type == "delta"
    end

    def done?
      type == "done"
    end
  end
end
