# frozen_string_literal: true

module Hanami
  module Webconsole
    module Presenters
      # Wraps a presenter so that none of its parts can raise.
      #
      # A presenter runs while a page is being built for an error that has already happened. A
      # part that raises falls back to {Base}'s default for that part alone, so one broken part
      # costs the page one section rather than the whole presenter. Presenters themselves are
      # then written as plain code.
      #
      # It rescues what {Backtrace} rescues: `ScriptError` because `NotImplementedError` is one,
      # and `SystemStackError` for a runaway recursion. Signals, `SystemExit`, timeouts and
      # `NoMemoryError` are not rescued: those must still stop the request.
      #
      # Each part is computed once, since the renderer reads some of them more than once.
      #
      # @api private
      class Guard
        # Each part of the {Base} interface, with the value it falls back to.
        PARTS = {
          headline: nil, lede: nil, command: nil, snippet: nil, note: nil,
          items: [].freeze, suggestions: [].freeze, context_panels: [].freeze
        }.freeze

        # @return [Base]
        attr_reader :presenter

        def initialize(presenter)
          @presenter = presenter
          @values = {}
        end

        # @return [Exception]
        def exception
          presenter.exception
        end

        PARTS.each do |part, fallback|
          define_method(part) do
            return @values[part] if @values.key?(part)

            @values[part] =
              begin
                presenter.public_send(part)
              rescue StandardError, ScriptError, SystemStackError
                fallback
              end
          end
        end
      end
    end
  end
end
