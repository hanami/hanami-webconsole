# frozen_string_literal: true

module Hanami
  module Webconsole
    module Diagnostics
      # Wraps a diagnostic so that the rest of webconsole can use it safely.
      #
      # Diagnostics are written by other people, and they run while we're building a page for an
      # error that has already happened. We don't want a bug in a diagnostic to stop that page from
      # rendering, so webconsole never calls a diagnostic directly. Instead, it goes through this
      # wrapper.
      #
      # The wrapper reads each part of the diagnostic (its title, explanation, fix and dataset) only
      # if the diagnostic implements it, and only once. It then normalizes each part into plain
      # values, such as strings, {Fix} and {Dataset}. If a part raises an error, it is treated as
      # missing, so a broken part doesn't disrupt the entire diagnostic.
      #
      # Running the fix also goes through the wrapper (see {#run_fix}), with the same guarantee: it
      # never raises.
      #
      # When reading parts, the wrapper rescues the same errors as {Backtrace}: `StandardError`,
      # `ScriptError` (since `NotImplementedError` is one) and `SystemStackError` (for a runaway
      # recursion). {#run_fix} goes further, and rescues any `Exception`.
      #
      # @api private
      class Wrapper
        # A diagnostic's fix, with an optional name.
        #
        # @!attribute [r] name
        #   @return [String, nil]
        # @!attribute [r] text
        #   @return [String]
        Fix = Data.define(:name, :text)

        # A diagnostic's dataset: rows of cells, with a title and optional column headings.
        #
        # @!attribute [r] title
        #   @return [String]
        # @!attribute [r] columns
        #   @return [Array<String>] empty when the dataset has no column headings
        # @!attribute [r] rows
        #   @return [Array<Array<String>>] every row as wide as the widest
        Dataset = Data.define(:title, :columns, :rows)

        # The result of running a fix: whether it worked, and the output to show on the page.
        #
        # @!attribute [r] ok
        #   @return [Boolean]
        # @!attribute [r] output
        #   @return [String]
        Result = Data.define(:ok, :output) do
          def ok? = !!ok
        end

        # The maximum length of a diagnostic's title, explanation or fix text.
        MAX_TEXT = 10_000

        # The maximum length of a shorter piece of text, such as a fix's name, a dataset's title, or
        # a cell in a dataset.
        MAX_CELL = 1_000

        # The maximum number of columns in a dataset.
        MAX_COLUMNS = 10

        # The maximum number of rows in a dataset.
        #
        # This is high on purpose. A dataset's panel on the page has a filter box, and the filter
        # only searches the rows on the page, so we want to keep every row of any realistic dataset,
        # such as the routes of a large app.
        MAX_ROWS = 10_000

        # The maximum length of the output from running a fix.
        MAX_OUTPUT = 4_000

        # The title to show for a dataset that doesn't have one.
        DEFAULT_DATASET_TITLE = "Details"

        # Builds a diagnostic for the given exception, and wraps it if it applies.
        #
        # @param diagnostic_class [Class] the registered diagnostic class
        # @param exception [Exception] the exception the diagnostic was registered for
        # @param context [Context]
        #
        # @return [Wrapper, nil] nil if the diagnostic doesn't apply, or raises an error when built
        def self.build(diagnostic_class, exception, context)
          diagnostic = diagnostic_class.new(exception, context)
          return nil if diagnostic.respond_to?(:applies?) && !diagnostic.applies?

          new(diagnostic)
        rescue StandardError, ScriptError, SystemStackError
          nil
        end

        # Returns the wrapped diagnostic.
        #
        # @return [Object]
        attr_reader :diagnostic

        # @param diagnostic [Object] the diagnostic to wrap
        def initialize(diagnostic)
          @diagnostic = diagnostic
          @values = {}
        end

        # Returns the diagnostic's title.
        #
        # This is a short name for the situation, shown on the page in place of the exception's
        # class name.
        #
        # @return [String, nil] nil if the diagnostic has no title
        def title
          read(:title) { |value| text(value) }
        end

        # Returns the diagnostic's explanation of why the exception was raised.
        #
        # @return [String, nil] nil if the diagnostic has no explanation
        def explanation
          read(:explanation) { |value| text(value) }
        end

        # Returns the diagnostic's fix.
        #
        # A diagnostic can give its fix as text, or as a hash of `{name:, text:}`. A fix without any
        # text is ignored.
        #
        # @return [Fix, nil] nil if the diagnostic has no fix
        def fix
          read(:fix) do |value|
            name, body = value.is_a?(Hash) ? value.values_at(:name, :text) : [nil, value]
            body = text(body)
            Fix.new(name: text(name, max: MAX_CELL), text: body) if body
          end
        end

        # Returns the diagnostic's dataset.
        #
        # A diagnostic gives its dataset as a hash of `{title:, columns:, rows:}`, where only `rows`
        # is required. See {#cell_rows} for the shapes that `rows` can take.
        #
        # Every row, along with the column headings, is padded to the same width. A dataset without
        # any rows is ignored.
        #
        # @return [Dataset, nil] nil if the diagnostic has no dataset
        def dataset
          read(:dataset) do |value|
            next unless value.is_a?(Hash)

            rows = cell_rows(value[:rows])
            next if rows.empty?

            columns = cells(value[:columns])
            width = [columns.length, *rows.map(&:length)].max

            Dataset.new(
              title: text(value[:title], max: MAX_CELL) || DEFAULT_DATASET_TITLE,
              columns: columns.empty? ? [] : pad(columns, width),
              rows: rows.map { |row| pad(row, width) }
            )
          end
        end

        # Returns true if the diagnostic has a fix that can be run from the page.
        #
        # This requires both a fix and a `run_fix` method. If the diagnostic has `run_fix` but no
        # fix, there's no fix card to show its button in, so `run_fix` is ignored.
        #
        # @return [Boolean]
        def runnable_fix?
          !fix.nil? && diagnostic.respond_to?(:run_fix)
        end

        # Runs the diagnostic's fix, and returns the result.
        #
        # Unlike reading the other parts, this rescues any `Exception`. Running a fix is a single
        # action that the developer asked for, so if it fails for any reason, the right thing to do
        # is to tell them that it failed, and why. The page also needs a result to show, no matter
        # what. (In practice, a fix will almost never see a signal, since signals go to the server's
        # main thread.)
        #
        # @return [Result] never raises
        def run_fix
          return Result.new(ok: false, output: "This fix can't run from the page.") unless runnable_fix?

          output = diagnostic.run_fix

          Result.new(ok: true, output: output.is_a?(String) ? output[0, MAX_OUTPUT] : "")
        rescue ::Exception => exception # rubocop:disable Lint/RescueException
          Result.new(ok: false, output: describe(exception))
        end

        private

        # Reads a part of the diagnostic, and returns its normalised value.
        #
        # This only calls the diagnostic's method for the part if the diagnostic defines it. The
        # method's return value is passed to the given block to be normalised. If the method raises
        # an error, the part is treated as missing.
        #
        # The value is memoised, including nil values, so each part is only read once.
        #
        # @param part [Symbol] the name of the diagnostic's method
        #
        # @yieldparam value [Object] the value returned by the diagnostic
        # @yieldreturn [Object, nil] the normalised value
        #
        # @return [Object, nil] the normalised value, or nil if the part is missing
        def read(part)
          return @values[part] if @values.key?(part)

          @values[part] =
            begin
              diagnostic.respond_to?(part) ? yield(diagnostic.public_send(part)) : nil
            rescue StandardError, ScriptError, SystemStackError
              nil
            end
        end

        # Converts the given value to a string, truncated to the given length.
        #
        # @param value [Object, nil]
        # @param max [Integer] the maximum length
        #
        # @return [String, nil] nil if the value is nil, or blank
        def text(value, max: MAX_TEXT)
          return nil if value.nil?

          string = value.to_s
          string.strip.empty? ? nil : string[0, max]
        end

        # Converts a dataset's rows into rows of cells.
        #
        # Rows can be given as an array, where each row is either an array of values, or a single
        # value (for a row with one cell). They can also be given as a hash, where each key and
        # value become a row of two cells.
        #
        # Empty rows are removed, and the number of rows is limited to {MAX_ROWS}.
        #
        # @param rows [Array, Hash, nil]
        #
        # @return [Array<Array<String>>]
        def cell_rows(rows)
          rows = rows.to_a if rows.is_a?(Hash)

          Array(rows).first(MAX_ROWS).map { |row| cells(row.is_a?(Array) ? row : [row]) }.reject(&:empty?)
        end

        # Converts a row of values (or the column headings) into cells.
        #
        # Each cell is a string, truncated to {MAX_CELL}, and the number of cells is limited to
        # {MAX_COLUMNS}. Unlike {#text}, blank values are kept as they are, since a blank cell is
        # still a cell.
        #
        # @param values [Array, nil]
        #
        # @return [Array<String>]
        def cells(values)
          Array(values).first(MAX_COLUMNS).map { |value| value.to_s[0, MAX_CELL] }
        end

        # Pads the given row with empty cells, up to the given width.
        #
        # @param row [Array<String>]
        # @param width [Integer]
        #
        # @return [Array<String>]
        def pad(row, width)
          row + Array.new(width - row.length, "")
        end

        # Returns a description of an error raised when running a fix, to show on the page.
        #
        # @param exception [Exception]
        #
        # @return [String] the error's class and message, or a fallback message if these can't be
        #   read
        def describe(exception)
          "#{Inspector.class_name(exception)}: #{exception.message}"
        rescue ::Exception # rubocop:disable Lint/RescueException
          "The fix failed, and its error could not be read."
        end
      end
    end
  end
end
