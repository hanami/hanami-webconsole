# frozen_string_literal: true

require_relative "../diagnostics"

module Hanami
  module Webconsole
    # Support for code that must never raise.
    #
    # The error page is built while handling an error that has already happened, so a failure while
    # building it would leave the developer with nothing at all. Code that reads from the exception,
    # the app or a diagnostic uses this to degrade to a safe value instead.
    #
    # @api private
    module Safety
      # The errors that code building the error page rescues.
      #
      # These are the same errors that diagnostics rescue (see {Hanami::Diagnostics::ERRORS}). This
      # includes `ScriptError`, because `NotImplementedError` is one. It leaves out signals,
      # `SystemExit`, timeouts and `NoMemoryError`, since those must still stop the request.
      ERRORS = Hanami::Diagnostics::ERRORS

      private

      # Returns the block's value, or the given fallback if the block raises one of {ERRORS}.
      #
      # @param fallback [Object]
      #
      # @return [Object]
      def safely(fallback)
        yield
      rescue *ERRORS
        fallback
      end
    end
  end
end
