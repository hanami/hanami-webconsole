# frozen_string_literal: true

if RUBY_ENGINE == "ruby"
  # Skip binding_of_caller's version check and force it to load on Ruby 4.0.
  #
  # Remove this shim once https://github.com/banister/binding_of_caller/pull/90 is merged and a new
  # release has been made.
  require "binding_of_caller/version"
  require "binding_of_caller/mri"

  # Prevent a direct require to "binding_of_caller", which is no longer needed by this point, and
  # which prints a misleading warning about it not supporting Ruby 4.0, which we've fixed ourselves
  # via the above.
  $LOADED_FEATURES << "binding_of_caller.rb"
else
  require "binding_of_caller"
end

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
