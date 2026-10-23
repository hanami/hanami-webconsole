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
      # The error page reads presenters through a {Guard}, so a part that raises falls back to
      # its default here. Subclasses need not rescue anything themselves.
      #
      # Subclasses are expected to override at least {#headline} and {#lede}.
      #
      # @api private
      class Base
        # The exception being presented.
        #
        # @return [Exception]
        attr_reader :exception

        def initialize(exception)
          @exception = exception
        end

        # Short, human title for the error, replacing the exception class name.
        #
        # @return [String, nil]
        def headline
          nil
        end

        # One or two sentences explaining the error in the developer's terms.
        #
        # Plain text: it is escaped before rendering.
        #
        # @return [String, nil]
        def lede
          nil
        end

        # A shell command that fixes the error, if there is one.
        #
        # @return [String, nil]
        def command
          nil
        end

        # A source snippet illustrating the fix, if there is one.
        #
        # @return [String, nil]
        def snippet
          nil
        end

        # Supporting facts, rendered as a list.
        #
        # @return [Array<String>]
        def items
          []
        end

        # A caveat or aside shown under the fix.
        #
        # @return [String, nil]
        def note
          nil
        end

        # Things to try, when there is no single fix.
        #
        # @return [Array<String>]
        def suggestions
          []
        end

        # Extra panels of context, beyond the ones the generic page always shows.
        #
        # Each panel is a `[title, rows]` pair, where each row is
        # `[name, value, filtered?, highlight?]`.
        #
        # @return [Array<Array>]
        def context_panels
          []
        end
      end
    end
  end
end
