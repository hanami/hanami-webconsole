# frozen_string_literal: true

require "better_errors"

module Hanami
  # Hanami web console for development
  #
  # @since 0.1.0
  module Webconsole
    require_relative "webconsole/version"
    require_relative "webconsole/middleware"
  end
end
