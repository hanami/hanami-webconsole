# frozen_string_literal: true

source "https://rubygems.org"

eval_gemfile "Gemfile.devtools"

gemspec

unless ENV["CI"]
  gem "yard"
end

if ENV["RACK_MATRIX_VALUE"]
  gem "rack", ENV["RACK_MATRIX_VALUE"]
end

group :test do
  gem "rspec", "~> 3.12"
  gem "rack-test"

  # For testing the NotFound diagnostic
  gem "hanami-router", github: "hanami/hanami-router", branch: "main"
end
