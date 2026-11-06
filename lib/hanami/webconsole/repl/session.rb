# frozen_string_literal: true

module Hanami
  module Webconsole
    # The interactive console.
    #
    # @api private
    module Repl
      # Evaluates source in the binding of one backtrace frame.
      #
      # The middleware builds a session for each evaluation. State still carries over from one
      # evaluation to the next (a local assigned in one is there in the next), because it lives in
      # the frame's binding, and the frame lives as long as the error page that holds it.
      class Session
        FILENAME = "(hanami-webconsole)"
        private_constant :FILENAME

        def initialize(binding)
          @binding = binding
        end

        # Evaluates source and returns what to print, plus whether it was an error.
        #
        # This must never raise. Whatever the developer types, and whatever it does to the
        # application, the answer is a string to show in the console. So this rescues any
        # `Exception`, including the ones a bare `rescue` misses: `SyntaxError` (raised by
        # `Binding#eval` itself, and not a `StandardError`), `SystemStackError`, and
        # `NoMemoryError`.
        #
        # @param source [String]
        #
        # @return [Array(String, Boolean)] the output, and whether it is an error
        def eval(source)
          result = @binding.eval(source.to_s, FILENAME, 1)

          [Inspector.call(result), false]
        rescue Exception => exception # rubocop:disable Lint/RescueException
          [format_error(exception), true]
        end

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
