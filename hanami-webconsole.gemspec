# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "hanami/webconsole/version"

Gem::Specification.new do |spec|
  spec.name          = "hanami-webconsole"
  spec.version       = Hanami::Webconsole::VERSION
  spec.authors       = ["Hanakai team"]
  spec.email         = ["info@hanakai.org"]
  spec.summary       = "Hanami webconsole"
  spec.description   = "Hanami webconsole for development"
  spec.homepage      = "http://hanamirb.org"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = `git ls-files -- lib/* CHANGELOG.md LICENSE.md README.md hanami-webconsole.gemspec`.split($INPUT_RECORD_SEPARATOR)
  spec.require_paths = ["lib"]

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.add_dependency "better_errors", "~> 2.10", ">= 2.10.1"
  spec.add_dependency "binding_of_caller", "~> 1.0"
end
