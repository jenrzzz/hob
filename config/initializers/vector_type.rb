# pgvector's `vector` (observations.embedding, MEMORY.md) is read and written
# as its text form ("[0.1,0.2,…]"); hob only ever compares vectors in SQL.
# Registered so ActiveRecord doesn't warn about an unknown OID on every boot.
ActiveSupport.on_load(:active_record_postgresqladapter) do
  singleton_class.prepend(Module.new do
    def initialize_type_map(map)
      super
      map.register_type("vector", ActiveRecord::Type::String.new)
    end
  end)
end
