# frozen_string_literal: true

require_relative "diagnostics/causes"
require_relative "diagnostics/context"
require_relative "diagnostics/registry"
require_relative "diagnostics/text"
require_relative "diagnostics/wrapper"

module Hanami
  # Registers diagnostics, which tell developers what went wrong with an error and how to fix it.
  #
  # Call this only from a `config/diagnostics.rb` in an app or slice directory, or the file named by
  # a gem's `hanami_diagnostics` gemspec metadata. For example:
  #
  #   # config/diagnostics.rb
  #   Hanami::Diagnostics.register "Sequel::DatabaseError", Bookshelf::Diagnostics::MissingTable
  #
  #   # In a gem, register the class name only. This file may load before the gem itself is
  #   # required, so the class may not be loadable yet. The class is loaded when an error needs it.
  #   Hanami::Diagnostics.register "ROM::ElementNotFoundError", "ROM::Diagnostics::UnknownComponent"
  #
  # Only Hanami Webconsole loads these files, and only after defining `Hanami::Diagnostics`, so a
  # diagnostics file can call it without checking for it being defined, and a gem needs no new
  # dependency to provide diagnostics. In all other places, this module may not exist, since in the
  # production and test environments, Webconsole isn't loaded at all.
  #
  # The `Hanami::Diagnostics` namespace is separate from `Hanami::Webconsole` to allow for future
  # consumers of diagnostics.
  #
  # **Experimental:** this API may change in a later release.
  #
  # @api public
  # @since 3.1.0
  module Diagnostics
    # The errors we rescue from code we don't control, such as a diagnostic's methods or a
    # diagnostics file, so that a broken diagnostic can't break the error page or stop the app from
    # booting.
    #
    # This is broader than `StandardError`: a diagnostics file with a syntax error raises a
    # `ScriptError`, and runaway recursion raises a `SystemStackError`. On JRuby, runaway recursion
    # raises Java's `StackOverflowError` instead, which isn't a `SystemStackError`.
    #
    # @api private
    ERRORS = [
      StandardError, ScriptError, SystemStackError,
      *(Java::JavaLang::StackOverflowError if RUBY_ENGINE == "jruby")
    ].freeze

    # Registers a diagnostic class for the exception class with the given name.
    #
    # The exception class is given by name, so registering doesn't load the gem that defines it. A
    # diagnostic registered for an exception class is also used for its subclasses. More than one
    # diagnostic can be registered for the same exception class: the most recently registered is
    # tried first, and the next is tried if it doesn't apply.
    #
    # The diagnostic is kept by name, and looked up when an error needs it. So after a code reload,
    # the current class is used. A gem can also give the diagnostic's name, so it isn't loaded
    # until it's needed.
    #
    # @param exception_class_name [String]
    # @param diagnostic [String, Class] the diagnostic class, or its name
    #
    # @return [void]
    #
    # @raise [ArgumentError] if the name isn't a non-empty string, or the diagnostic isn't a class
    #   or a non-empty string
    #
    # @api public
    # @since 3.1.0
    def self.register(exception_class_name, diagnostic)
      unless Registry.loading_file?
        warn "hanami-webconsole: #{caller_locations(1, 1).first}: call Hanami::Diagnostics.register " \
          "only from config/diagnostics.rb or a gem's `hanami_diagnostics` file. In other places, " \
          "it will raise errors when hanami-webconsole isn't loaded, such as in production."
      end

      Registry.register(exception_class_name, diagnostic)
    end
  end
end
