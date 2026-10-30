# frozen_string_literal: true

module Hanami
  module Diagnostics
    # Finds the causes of an exception.
    #
    # Diagnostics lookup walks these, outermost first, when no diagnostic applies to the exception
    # itself. Webconsole shows the same causes on the error page, so they always match what lookup
    # walked.
    #
    # @api private
    module Causes
      # The maximum number of causes to look through.
      #
      # A cause chain could be very long, or even loop back on itself, so we stop after this many.
      MAX = 10

      class << self
        # Returns the causes of the given exception, from outermost to innermost.
        #
        # This stops after {MAX} causes, at any cause that isn't an exception, and at any cause it
        # has already seen (including the given exception itself), so a cause chain that loops back
        # on itself can't hang the error page.
        #
        # This never raises. If a cause can't be read, the causes found so far are returned.
        #
        # @param exception [Exception]
        #
        # @return [Array<Exception>]
        def of(exception)
          causes = []
          current = exception

          MAX.times do
            current = current.cause
            break unless current.is_a?(Exception)
            break if current.equal?(exception) || causes.any? { |cause| cause.equal?(current) }

            causes << current
          end

          causes
        rescue *ERRORS
          causes
        end
      end
    end
  end
end
