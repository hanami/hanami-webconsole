# frozen_string_literal: true

source "https://rubygems.org"

eval_gemfile "Gemfile.devtools"

gemspec

unless ENV["CI"]
  gem "yard"
end

group :test do
  gem "rspec", "~> 3.12"
end
