require_relative "lib/wazowski/version"

Gem::Specification.new do |spec|
  spec.name          = "wazowski"
  spec.version       = Wazowski::VERSION
  spec.authors       = ["Roger Campos"]
  spec.email         = ["roger@rogercampos.com"]

  spec.summary       = "Declarative Active Record data observers"
  spec.description   = "Run your code when the data you declare to observe changes, once per transaction."
  spec.homepage      = "https://github.com/rogercampos/wazowski"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files         = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.3.0"

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
end
