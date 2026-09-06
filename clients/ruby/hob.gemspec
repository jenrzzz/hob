require_relative "lib/hob/version"

Gem::Specification.new do |spec|
  spec.name    = "hob"
  spec.version = Hob::VERSION
  spec.authors = [ "Jenner" ]
  spec.email   = [ "jenner@jfave.com" ]

  spec.summary     = "Client for hob, a personal LLM substrate."
  spec.description = "hob is the household spirit: one backing service through which " \
                     "every LLM interaction flows — providers, conversations, personas, " \
                     "memory, tools, compute, and voice. This gem is the Ruby client: " \
                     "complete, chat, conversations, usage, and a fake for tests."
  spec.license = "MIT"
  spec.homepage = "https://github.com/jenrzzz/hob"

  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb"] + [ "README.md" ]
  spec.require_paths = [ "lib" ]

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/jenrzzz/hob/tree/main/clients/ruby"

  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake", ">= 13.0"
end
