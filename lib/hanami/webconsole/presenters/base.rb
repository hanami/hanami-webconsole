# frozen_string_literal: true

module Hanami
  module Webconsole
    module Presenters
      # Base class for actionable error presenters.
      #
      # A presenter turns a recognised exception into an explanation and a fix: it leads with what
      # went wrong in the developer's terms, and demotes the backtrace to a disclosure. Everything
      # here returns a safe default, so a subclass only implements the parts it can speak to.
      #
      # Subclasses are expected to override at least {#headline} and {#lede}.
      #
      # @api private
      # @since 3.1.0
      class Base
        # The exception being presented.
        #
        # @return [Exception]
        #
        # @api private
        # @since 3.1.0
        attr_reader :exception

        # @api private
        # @since 3.1.0
        def initialize(exception)
          @exception = exception
        end

        # Short, human title for the error, replacing the exception class name.
        #
        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def headline
          nil
        end

        # One or two sentences explaining the error in the developer's terms.
        #
        # Plain text: it is escaped before rendering.
        #
        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def lede
          nil
        end

        # A shell command that fixes the error, if there is one.
        #
        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def command
          nil
        end

        # A source snippet illustrating the fix, if there is one.
        #
        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def snippet
          nil
        end

        # Supporting facts, rendered as a list.
        #
        # @return [Array<String>]
        #
        # @api private
        # @since 3.1.0
        def items
          []
        end

        # A caveat or aside shown under the fix.
        #
        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def note
          nil
        end

        # Things to try, when there is no single fix.
        #
        # @return [Array<String>]
        #
        # @api private
        # @since 3.1.0
        def suggestions
          []
        end

        # Extra panels of context, beyond the ones the generic page always shows.
        #
        # Each panel is a `[title, rows]` pair, where each row is
        # `[name, value, filtered?, highlight?]`.
        #
        # @return [Array<Array>]
        #
        # @api private
        # @since 3.1.0
        def context_panels
          []
        end
      end
    end
  end
end
