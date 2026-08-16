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
    # @since 3.1.0
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
    # @since 3.1.0
    def self.probe_bindings(prober = -> { ::Kernel.binding.callers })
      require "binding_of_caller"
      prober.call
      true
    rescue ScriptError, StandardError # LoadError is a ScriptError
      false
    end

    @bindings_available = probe_bindings

    # Name of the CSRF cookie set alongside the error page.
    #
    # Defined here because both the middleware (which sets the cookie and validates the token)
    # and the renderer (which embeds the token in the page) need it, and they must never
    # disagree. The cookie is `httponly`, so JavaScript cannot read it back — the same token is
    # embedded in the page for the double-submit check.
    #
    # @api private
    # @since 3.1.0
    CSRF_COOKIE_NAME = "Hanami-Webconsole-CSRF-Token"

    # Path the console's internal endpoints are mounted at.
    #
    # @api private
    # @since 3.1.0
    MOUNT_PATH = "/_hanami/webconsole"

    # Generation counter, bumped whenever application code is reloaded.
    #
    # Error page IDs are stamped with the generation that created them. After a reload, the
    # bindings a page holds refer to constants that have since been unloaded, so evaluating
    # against them would silently use stale classes. Pages from an older generation are dropped
    # instead, and the console reports that the session has expired.
    #
    # @api private
    # @since 3.1.0
    def self.generation
      @generation ||= 0
    end

    # @api private
    # @since 3.1.0
    def self.reloaded!
      @generation = generation + 1
    end

    require_relative "webconsole/version"

    # Required in dependency order. This gem is loaded lazily by `Hanami::Slice`, only in
    # development, so there is nothing to gain from autoloading.
    # Must come first: it hooks `Exception#set_backtrace`, and only exceptions raised after it
    # is installed carry bindings.
    require_relative "webconsole/exception_extension"

    require_relative "webconsole/inspector"
    require_relative "webconsole/filters"
    require_relative "webconsole/source_file"
    require_relative "webconsole/frame"
    require_relative "webconsole/backtrace"
    require_relative "webconsole/request_context"
    require_relative "webconsole/resolution"
    require_relative "webconsole/presenters/base"
    require_relative "webconsole/presenters"
    require_relative "webconsole/presenters/not_found"
    require_relative "webconsole/repl/session"
    require_relative "webconsole/error_page"
    require_relative "webconsole/registry"
    require_relative "webconsole/editor"
    require_relative "webconsole/renderer"
    require_relative "webconsole/middleware"
  end
end
