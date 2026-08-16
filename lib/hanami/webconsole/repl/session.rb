# frozen_string_literal: true

module Hanami
  module Webconsole
    # The interactive console.
    #
    # @api private
    # @since 3.1.0
    module Repl
      # Evaluates source in the binding of one backtrace frame.
      #
      # One session belongs to one frame, and lives as long as the error page holding that frame —
      # which is to say, until the next code reload drops it from the {Registry}.
      #
      # @api private
      # @since 3.1.0
      class Session
        # @api private
        # @since 3.1.0
        FILENAME = "(hanami-webconsole)"
        private_constant :FILENAME

        # @api private
        # @since 3.1.0
        def initialize(binding)
          @binding = binding
        end

        # Evaluates source and returns what to print, plus whether it was an error.
        #
        # This must never raise. Whatever the developer types, and whatever it does to the
        # application, the answer is a string to show in the console — including for the classes
        # a bare `rescue` misses: `SyntaxError` (raised by `Binding#eval` itself, and not a
        # `StandardError`), `SystemStackError`, and `NoMemoryError`.
        #
        # @param source [String]
        #
        # @return [Array(String, Boolean)] the output, and whether it is an error
        #
        # @api private
        # @since 3.1.0
        def eval(source)
          result = @binding.eval(source.to_s, FILENAME, 1)

          [Inspector.call(result), false]
        # rubocop:disable Lint/RescueException, Lint/ShadowedException
        rescue SyntaxError, SystemStackError, NoMemoryError, StandardError, Exception => exception
          [format_error(exception), true]
        end
        # rubocop:enable Lint/RescueException, Lint/ShadowedException

        private

        def format_error(exception)
          class_name = error_class_name(exception)
          message = error_message(exception)

          message.empty? ? class_name : "#{class_name}: #{message}"
        end

        def error_class_name(exception)
          Inspector.class_name(exception)
        rescue Exception # rubocop:disable Lint/RescueException
          "Exception"
        end

        def error_message(exception)
          exception.message.to_s
        rescue Exception # rubocop:disable Lint/RescueException
          ""
        end
      end
    end
  end
end
