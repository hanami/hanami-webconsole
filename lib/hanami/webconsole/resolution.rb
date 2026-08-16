# frozen_string_literal: true

module Hanami
  module Webconsole
    # A step the developer can take to fix an error, offered by the error itself.
    #
    # An exception is resolvable if it responds to `#resolutions`, returning objects that respond
    # to `#name` and to any of:
    #
    #   #call(context)  runs the fix; without it the resolution is guidance only
    #   #destructive?   requires a confirming second click, default false
    #   #command        a shell command, shown copyable
    #   #snippet        code to paste, shown highlighted and copyable
    #   #items          a list of files, keys or candidates
    #   #note           prose specific to this error
    #
    # There is no module to include and no constant to inherit, so a gem can offer resolutions
    # without taking on a dependency, and an app can define them on its own errors.
    #
    # A resolution may be both: a button that runs the fix *and* the command to run it by hand
    # are one resolution offered two ways, not two competing resolutions.
    #
    #   class PendingMigrationError < StandardError
    #     Resolution = Struct.new(:name, :run) do
    #       def destructive? = false
    #       def call(context) = run.call(context)
    #     end
    #
    #     def resolutions
    #       [Resolution.new("Run pending migrations", ->(context) { DB.migrate(context.app) })]
    #     end
    #   end
    #
    # Note the lambda rather than a block: `Struct#new` discards a block passed to it, so a
    # hand-rolled resolution has to hold the callable in a member.
    #
    # Because `#resolutions` is an instance method, that lambda is an ordinary closure over the
    # error, so a resolution can read whatever the error knows without any binding gymnastics.
    #
    # Everything arriving here is written by someone else, so it is normalised into this class
    # rather than passed around as-is, and nothing it does may raise.
    #
    # @api private
    # @since 3.1.0
    class Resolution
      # What a resolution is handed when it runs.
      #
      # Deliberately thin. Once gems write resolutions against this it is public API, and adding
      # to it later is easy where taking things away is not.
      #
      # @api private
      # @since 3.1.0
      Context = Struct.new(:app, :slice, :request, keyword_init: true)

      # @api private
      # @since 3.1.0
      Result = Struct.new(:ok, :output, keyword_init: true) do
        # @api private
        # @since 3.1.0
        def ok? = !!ok
      end

      # Longest accepted value for any single piece of guidance.
      #
      # @api private
      # @since 3.1.0
      MAX_TEXT = 10_000

      # @api private
      # @since 3.1.0
      MAX_ITEMS = 50

      # Reads the resolutions an exception offers.
      #
      # @param exception [Exception]
      #
      # @return [Array<Resolution>] empty for any error that offers none, or offers something
      #   that does not fit the contract
      #
      # @api private
      # @since 3.1.0
      def self.for(exception)
        return [] unless exception.respond_to?(:resolutions)

        Array(exception.resolutions).filter_map { |candidate| build(candidate) }
      rescue ::Exception # rubocop:disable Lint/RescueException
        # `resolutions` is arbitrary user code. An error page that cannot render because the
        # error's own resolutions raised would be worse than one with no resolutions at all.
        []
      end

      # @api private
      # @since 3.1.0
      def self.build(candidate)
        name = name_of(candidate)
        return unless name

        executable = candidate.respond_to?(:call)
        content = content_of(candidate)

        # A resolution that can neither run nor say anything is a button with nothing behind it.
        return if !executable && content.values.all? { |value| value.nil? || value == [] }

        new(name: name, executable: executable, target: candidate,
          destructive: destructive?(candidate), **content)
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end
      private_class_method :build

      # @api private
      # @since 3.1.0
      def self.name_of(candidate)
        return unless candidate.respond_to?(:name)

        name = candidate.name.to_s
        name.empty? ? nil : name
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end
      private_class_method :name_of

      # @api private
      # @since 3.1.0
      def self.content_of(candidate)
        content = %i[command snippet note].to_h { |key| [key, text(candidate, key)] }
        content[:items] = items(candidate)
        content
      end
      private_class_method :content_of

      # @api private
      # @since 3.1.0
      def self.destructive?(candidate)
        candidate.respond_to?(:destructive?) && !!candidate.destructive?
      rescue ::Exception # rubocop:disable Lint/RescueException
        false
      end
      private_class_method :destructive?

      # @api private
      # @since 3.1.0
      def self.text(candidate, method)
        return unless candidate.respond_to?(method)

        value = candidate.public_send(method)
        return if value.nil?

        string = value.to_s
        return if string.empty?

        string[0, MAX_TEXT]
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end
      private_class_method :text

      # @api private
      # @since 3.1.0
      def self.items(candidate)
        return [] unless candidate.respond_to?(:items)

        Array(candidate.items).first(MAX_ITEMS).filter_map { |item|
          string = item.to_s
          string.empty? ? nil : string[0, MAX_TEXT]
        }
      rescue ::Exception # rubocop:disable Lint/RescueException
        []
      end
      private_class_method :items

      # @api private
      # @since 3.1.0
      attr_reader :name, :command, :snippet, :note, :items

      # @api private
      # @since 3.1.0
      def initialize(name:, destructive:, target:, executable: true,
                     command: nil, snippet: nil, note: nil, items: [])
        @name = name
        @destructive = destructive
        @target = target
        @executable = executable
        @command = command
        @snippet = snippet
        @note = note
        @items = items
      end
      # rubocop:enable Metrics/ParameterLists

      # Whether this resolution can be run from the page.
      #
      # A resolution without `#call` is guidance: a command to type, a snippet to paste, a list
      # to work through. It renders in the same card with the same copy affordances, but there is
      # no button and nothing to execute — so it needs none of the endpoint's machinery.
      #
      # @return [Boolean]
      #
      # @api private
      # @since 3.1.0
      def executable? = @executable

      # Whether there is anything to show beyond the name and a button.
      #
      # @return [Boolean]
      #
      # @api private
      # @since 3.1.0
      def guidance? = !(command.nil? && snippet.nil? && note.nil? && items.empty?)

      # Whether running this changes something the developer may not want changed.
      #
      # Rolling back a migration drops columns; running one does not. The page asks for
      # confirmation on anything flagged here, so a destructive resolution is never one click
      # away on a page that appears by itself when something breaks.
      #
      # @return [Boolean]
      #
      # @api private
      # @since 3.1.0
      def destructive? = @destructive

      # Runs the resolution.
      #
      # @param context [Context]
      #
      # @return [Result] never raises; a failure is a Result, not an exception
      #
      # @api private
      # @since 3.1.0
      def call(context)
        unless executable?
          return Result.new(ok: false, output: "This resolution is guidance only.")
        end

        output = @target.call(context)

        Result.new(ok: true, output: format_output(output))
      rescue ::Exception => exception # rubocop:disable Lint/RescueException
        Result.new(ok: false, output: format_exception(exception))
      end

      private

      # @api private
      # @since 3.1.0
      def format_output(output)
        return "" if output.nil? || output == true

        Inspector.call(output, limit: 4_000)
      end

      # @api private
      # @since 3.1.0
      def format_exception(exception)
        "#{Inspector.class_name(exception)}: #{exception.message}"
      rescue ::Exception # rubocop:disable Lint/RescueException
        "The resolution failed, and its error could not be read."
      end
    end
  end
end
