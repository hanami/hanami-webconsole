# frozen_string_literal: true

module Hanami
  module Webconsole
    # Captures a `Binding` for each frame at the moment an exception is raised.
    #
    # This is the only way to get local variables and a working console: by the time the
    # middleware rescues an exception, the stack that raised it is gone. `Exception#set_backtrace`
    # is called by the interpreter as the exception propagates, which is the last point where
    # those frames are still live.
    #
    # Ported from better_errors, which this gem replaces. Installed only when
    # {Webconsole.bindings_available?}, since `binding.callers` comes from binding_of_caller.
    #
    # NOTE: this runs for *every* exception raised in the process, including ones that are
    # rescued and never seen. That is a real cost, which is why the gem belongs in the
    # `:development` group only.
    #
    # @api private
    # @since 3.1.0
    module ExceptionExtension
      @capturing = true

      class << self
        # @api private
        # @since 3.1.0
        def capturing?
          @capturing
        end

        # Gives up on binding capture for the rest of the process. Locals and the console go
        # away; everything else on the error page keeps working.
        #
        # @api private
        # @since 3.1.0
        def stand_down!
          @capturing = false
        end
      end

      # @api private
      # @since 3.1.0
      def set_backtrace(*)
        # `set_backtrace` can be called more than once as an exception propagates, and re-raising
        # would otherwise overwrite the original frames with the (shorter, less useful) stack of
        # the re-raise site. Guarding on our own file keeps the first capture.
        if ExceptionExtension.capturing? && caller_locations.none? { |location| location.path == __FILE__ }
          begin
            @__hanami_webconsole_bindings = ::Kernel.binding.callers.drop(1)
          rescue ::Exception # rubocop:disable Lint/RescueException
            # This runs for every exception raised anywhere in the process. If capturing ever
            # fails, swallowing it and standing down permanently is the only safe move —
            # raising from here would replace the user's exception with ours.
            ExceptionExtension.stand_down!
          end
        end

        super
      end

      # @return [Array<Binding>]
      #
      # @api private
      # @since 3.1.0
      def __hanami_webconsole_bindings
        @__hanami_webconsole_bindings || []
      end
    end

    Exception.prepend(ExceptionExtension) if bindings_available?
  end
end
