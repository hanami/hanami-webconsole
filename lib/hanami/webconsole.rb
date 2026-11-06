# frozen_string_literal: true

module Hanami
  # Hanami web console for development
  #
  # @since 0.1.0
  module Webconsole
    # Whether a real `Binding` can be captured for each backtrace frame.
    #
    # This requires binding_of_caller, which reaches into the VM's internal frame
    # representation. It is a declared dependency, but it must never be fatal: if it fails on a
    # given Ruby, the error page still renders, minus local variables and the console.
    #
    # @api private
    def self.bindings_available?
      @bindings_available
    end

    # Loading is not the same as working, so this probes rather than trusting `require`.
    #
    # On JRuby the gem loads fine and then `binding.callers` raises `NoMethodError` the first
    # time it is called, from inside `Exception#set_backtrace` — which runs for every exception
    # in the process. A load-only check would leave the whole app broken rather than degrading.
    #
    # @param prober [#call] seam for testing; must exercise the same call the extension makes
    #
    # @return [Boolean]
    #
    # @api private
    def self.probe_bindings(prober = -> { ::Kernel.binding.callers })
      require "binding_of_caller"
      prober.call
      true
    rescue ScriptError, StandardError # LoadError is a ScriptError
      false
    end

    @bindings_available = probe_bindings

    # Path the console's internal endpoints are mounted at.
    #
    # @api private
    MOUNT_PATH = "/_hanami/webconsole"

    require_relative "webconsole/version"

    # Must come first: it hooks `Exception#set_backtrace`, and only exceptions raised after it
    # is installed carry bindings.
    require_relative "webconsole/exception_extension"

    # Each file requires what it needs at load time, so these are in alphabetical order.
    require_relative "diagnostics"
    require_relative "webconsole/backtrace"
    require_relative "webconsole/editor"
    require_relative "webconsole/error_page"
    require_relative "webconsole/filters"
    require_relative "webconsole/frame"
    require_relative "webconsole/inspector"
    require_relative "webconsole/middleware"
    require_relative "webconsole/registry"
    require_relative "webconsole/rendering"
    require_relative "webconsole/repl/session"
    require_relative "webconsole/request_context"
    require_relative "webconsole/safety"
    require_relative "webconsole/source_file"

    # Register our own diagnostics.
    require_relative "webconsole/diagnostics/not_found"

    # Load diagnostics from gems. We do this once only at load time, since gems aren't part of
    # Hanami reloads.
    #
    # Do this after our own diagnostics, so that if a gem registers a diagnostic for the same error,
    # the gem's diagnostic is tried first.
    Hanami::Diagnostics::Registry.load_gem_files
  end
end
