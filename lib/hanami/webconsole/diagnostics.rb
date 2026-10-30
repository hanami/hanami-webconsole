# frozen_string_literal: true

module Hanami
  module Webconsole
    # Diagnostics tell Hanami app developers what went wrong with an error and how to fix it.
    #
    # A diagnostic is a plain class, built with an exception and a {Context}. Every method is
    # optional:
    #
    # - `applies?`: whether the diagnostic applies to this exception. A diagnostic is only built for
    #   exceptions of its registered class (or a subclass), so this can check the details on the
    #   exception instance itself. If false, the diagnostic is skipped and the next matching one is
    #   tried. Defaults to true.
    # - `title`: a short name for the situation, shown in place of the exception class name. The
    #   exception message is always shown below it, so don't restate the message.
    # - `explanation`: text explaining why the exception was raised, shown after the exception
    #   message. Use it only for what the message doesn't already say, such as a cause the
    #   diagnostic found by checking the app.
    # - `fix`: instructions on how to fix it, as text or `{name:, text:}`.
    # - `run_fix`: performs a runnable fix when the developer clicks its button on the page. The
    #   button only appears when `fix` returns a fix with some text. If `run_fix` returns a string,
    #   the page shows it as the fix's output. If it raises, the page shows the fix as failed, with
    #   the error.
    # - `dataset`: evidence from app state, as `{title:, columns:, rows:}`.
    #
    # Text uses the same format as exception messages (see {Text}). If you control the exception
    # class, write a good message there first. Use a diagnostic only for what a message can't give:
    # details from the running app, or a fix that runs from the page.
    #
    # Diagnostics are kept separate from the errors they describe, so error classes carry no
    # development-specific code into production. For now, there is no base class and no DSL, so a
    # diagnostic needs nothing from Hanami Webconsole.
    #
    # The diagnostic contract is currently experimental.
    #
    # @api private
    module Diagnostics
      # Context for a diagnostic, given to it alongside the exception when it is built.
      #
      # This gives the diagnostic access to the running app.
      #
      # @!attribute [r] slice
      #   @return [Hanami::Slice, nil] the slice that the webconsole middleware belongs to. Since
      #     slice routes are loaded into the app's router, this will nearly always be the app
      #     itself.
      Context = Data.define(:slice)

      # The maximum number of causes to look through when finding a diagnostic for an exception.
      #
      # A cause chain could be very long, or even loop back on itself, so we stop after this many.
      MAX_CAUSES = 10
      private_constant :MAX_CAUSES

      # The registered diagnostics.
      @registry = {}

      class << self
        # Returns the registered diagnostic classes, keyed by exception class name.
        #
        # This is exposed so that specs can save and restore the registry around their examples.
        #
        # @return [Hash{String => Class}]
        attr_reader :registry

        # Registers a diagnostic class for the given exception class.
        #
        # The exception class is given by name, as a string, so registering a diagnostic doesn't
        # require loading the gem that defines the exception.
        #
        # A diagnostic registered for an exception class is also used for that class's subclasses.
        #
        # @param exception_class_name [String]
        # @param diagnostic_class [Class]
        #
        # @return [Class] the diagnostic class
        def register(exception_class_name, diagnostic_class)
          @registry[exception_class_name.to_s] = diagnostic_class
        end

        # Returns the diagnostic for the given exception, wrapped and ready to use, or nil if no
        # diagnostic applies.
        #
        # This looks for a diagnostic registered for the exception's class or any of its ancestors.
        # If none applies, it does the same for each of the exception's causes, starting from the
        # outermost.
        #
        # The first diagnostic that applies is used. Diagnostics that don't apply (or that raise an
        # error when built) are skipped. This means a diagnostic registered for a broad exception
        # class can't get in the way of a more specific one further along the chain.
        #
        # @param exception [Exception]
        # @param context [Context]
        #
        # @return [Wrapper, nil]
        def for(exception, context)
          errors(exception).each do |error|
            diagnostic_classes(error).each do |diagnostic_class|
              diagnostic = Wrapper.build(diagnostic_class, error, context)
              return diagnostic if diagnostic
            end
          end

          nil
        end

        private

        # Returns the given exception followed by its causes, from outermost to innermost.
        #
        # This stops after {MAX_CAUSES} causes, at any cause that isn't an exception, and at any
        # cause it has already seen, so a cause chain that loops back on itself can't hang the
        # error page.
        #
        # @param exception [Exception]
        #
        # @return [Array<Exception>]
        def errors(exception)
          errors = [exception]

          MAX_CAUSES.times do
            cause = errors.last.cause
            break unless cause.is_a?(Exception)
            break if errors.any? { |error| error.equal?(cause) }

            errors << cause
          end

          errors
        rescue StandardError
          errors
        end

        # Returns the diagnostic classes registered for the given error's class and its ancestors,
        # with the closest class first.
        #
        # Anonymous classes are skipped, since diagnostics are registered by class name.
        #
        # @param error [Exception]
        #
        # @return [Array<Class>]
        def diagnostic_classes(error)
          error.class.ancestors.filter_map { |ancestor|
            name = ancestor.name
            @registry[name] if name
          }
        rescue StandardError
          []
        end
      end
    end
  end
end
