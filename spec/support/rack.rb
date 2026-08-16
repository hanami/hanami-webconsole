# frozen_string_literal: true

require "rack/test"

RSpec.configure do |config|
  # Specs tagged `type: :rack` drive a middleware through rack-test. They must define an `app`.
  config.include Rack::Test::Methods, type: :rack
end
