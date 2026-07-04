require_relative "lib/hob/version"

Gem::Specification.new do |spec|
  spec.name    = "hob"
  spec.version = Hob::VERSION
  spec.authors = ["Jenner"]
  spec.email   = ["jenner@jfave.com"]

  spec.summary     = "Client for hob, a personal LLM substrate."
  spec.description = "hob is the household spirit: one backing service through which " \
                     "every LLM interaction flows — providers, conversations, personas, " \
                     "memory, tools, compute, and voice. This gem is the Ruby client. " \
                     "0.0.x releases are name reservations while v1 is built."
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
end
