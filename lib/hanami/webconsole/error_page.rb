# frozen_string_literal: true

require "rack/utils"
require "securerandom"

require_relative "diagnostics"
require_relative "text"

module Hanami
  module Webconsole
    # The view model for a single error.
    #
    # Nothing on this object raises, otherwise the error page cannot render at all, so every value
    # degrades to something safe.
    #
    # @api private
    class ErrorPage
      # Status used when the exception maps to nothing in `config.render_error_responses`.
      DEFAULT_ERROR_RESPONSE = :internal_server_error

      # Status code used as a safe fallback for {#status}.
      DEFAULT_STATUS = 500

      # Maximum number of steps to take when computing an exception's causes.
      MAX_CAUSES = 10

      # Frames listed by {#to_text} before truncating.
      MAX_TEXT_FRAMES = 25

      attr_reader :exception

      attr_reader :env

      attr_reader :config

      # The id under which this page is stored in the {Registry}.
      #
      # Stamped with the generation that created it, so that a page outliving a code reload can be
      # recognised and dropped rather than evaluated against unloaded constants.
      #
      # @return [String]
      attr_reader :id

      # @return [Integer]
      attr_reader :generation

      # Builds a page id for the given generation.
      #
      # @return [String]
      def self.generate_id(generation = Webconsole.generation)
        "#{generation}-#{SecureRandom.hex(8)}"
      end

      # @param exception [Exception]
      # @param env [Hash] the Rack env
      # @param config [Hanami::Config] the app config
      # @param id [String, nil]
      # @param generation [Integer]
      # @param bindings [Array<Binding>, nil] bindings aligned to the exception's backtrace
      # @param slice [Hanami::Slice, nil] the slice the middleware belongs to, for diagnostics
      def initialize(exception:, env:, config:, id: nil, generation: Webconsole.generation, bindings: nil, slice: nil)
        @exception = exception
        @env = env || {}
        @config = config
        @generation = generation
        @id = id || self.class.generate_id(generation)
        @bindings = bindings
        @slice = slice
      end

      # @return [String]
      def exception_class
        @exception_class ||= class_name_of(exception)
      end

      # @return [String]
      def message
        @message ||= safely("") { exception.message.to_s }
      end

      # The lines `detailed_message` adds beyond `message`.
      #
      # On Ruby 3.1+ this is where `did_you_mean`'s suggestions and `error_highlight`'s caret live.
      # They are the most immediately useful thing about a `NoMethodError`, and they are not part
      # of `message`, so they are diffed out of `detailed_message` rather than recomputed.
      #
      # @return [Array<String>]
      def detailed_extras
        @detailed_extras ||= compute_detailed_extras
      end

      # The response status for this exception, per `config.render_error_responses`.
      #
      # @return [Integer]
      def status
        @status ||= safely(DEFAULT_STATUS) { Rack::Utils.status_code(error_response) }
      end

      # Returns true if the diagnostic offers a fix.
      #
      # When a fix is present, it leads and the backtrace starts collapsed. Otherwise the backtrace
      # is the developer's best lead, so it stays open.
      #
      # @return [Boolean]
      def actionable?
        !diagnostic&.fix.nil?
      end

      # The diagnostic for this exception, when one applies, wrapped so it's safe to use.
      #
      # Built once, so the run endpoint runs the fix on the same diagnostic that rendered the
      # page.
      #
      # @return [Diagnostics::Wrapper, nil]
      def diagnostic
        return @diagnostic if defined?(@diagnostic)

        @diagnostic = safely(nil) { Diagnostics.for(exception, Diagnostics::Context.new(slice: @slice)) }
      end

      # Class names of the exception's causes, outermost cause last.
      #
      # @return [Array<String>]
      def causes
        @causes ||= compute_causes
      end

      # @return [Backtrace]
      def backtrace
        @backtrace ||= Backtrace.new(exception: exception, root: root, bindings: @bindings)
      end

      # @return [Array<Frame>]
      def frames
        @frames ||= safely([]) { backtrace.frames }
      end

      # @return [Array<Frame>]
      def app_frames
        @app_frames ||= safely([]) { backtrace.app_frames }
      end

      # @return [RequestContext]
      def request
        @request ||= RequestContext.new(env: env, filters: filters)
      end

      # @return [Filters]
      def filters
        @filters ||= Filters.new(filter_keys)
      end

      # The app root, used to classify frames.
      #
      # @return [String]
      def root
        @root ||= safely(Dir.pwd) {
          config.respond_to?(:root) ? config.root.to_s : Dir.pwd
        }
      end

      # The whole error as Markdown.
      #
      # This backs both the "Copy as text" button and the `text/plain` response, so it has two
      # audiences: a GitHub issue or an LLM prompt, and a terminal. It is a deliverable, not a
      # debug dump — app frames are indented and gem frames are commented out, so the shape of the
      # stack is readable at a glance.
      #
      # @return [String]
      def to_text
        safely(fallback_text) { text_blocks.compact.join("\n\n") + "\n" }
      end

      private

      # In the same order as the page. A diagnostic's title isn't included: it's a label for the
      # page's headline, and here the class name and message already say what it says.
      #
      # Text in diagnostics is already Markdown, so it passes through as it is.
      def text_blocks
        [
          "## #{exception_class}",
          message.empty? ? nil : message,
          extras_block,
          diagnostic_text(&:explanation),
          metadata_block,
          diagnostic_text { |diagnostic| fix_text(diagnostic.fix) if diagnostic.fix },
          diagnostic_text { |diagnostic| dataset_text(diagnostic.dataset) if diagnostic.dataset },
          backtrace_block,
          source_block
        ]
      end

      def metadata_block
        bullets = []
        bullets << "- Request: #{request_summary}" if request_summary
        bullets << "- Status: #{status}"
        bullets << "- Caused by: #{causes.join(' → ')}" if causes.any?
        bullets.join("\n")
      end

      def request_summary
        return @request_summary if defined?(@request_summary)

        @request_summary = safely(nil) {
          summary = "#{request.method_name} #{request.path}".strip
          summary.empty? ? nil : summary
        }
      end

      # One part of the diagnostic as text, or nil when there's no diagnostic or no such part.
      def diagnostic_text
        diagnostic = self.diagnostic
        return nil unless diagnostic

        safely(nil) { yield(diagnostic) }
      end

      def fix_text(fix)
        heading = fix.name ? "### Fix: #{fix.name}" : "### Fix it"
        "#{heading}\n\n#{fix.text.strip}"
      end

      # A table with column headings becomes a Markdown table. Without them, it becomes a list.
      def dataset_text(dataset)
        rows =
          if dataset.columns.any?
            [
              table_row(dataset.columns),
              table_row(dataset.columns.map { "---" }),
              *dataset.rows.map { |row| table_row(row) }
            ]
          else
            dataset.rows.map { |row| "- #{row.reject(&:empty?).join(" — ")}" }
          end

        "### #{dataset.title}\n\n#{rows.join("\n")}"
      end

      def table_row(cells)
        "| #{cells.map { |cell| cell.gsub("|", "\\|") }.join(" | ")} |"
      end

      def extras_block
        return nil if detailed_extras.empty?

        detailed_extras.join("\n")
      end

      def backtrace_block
        listed = frames.first(MAX_TEXT_FRAMES)
        return nil if listed.empty?

        lines = [backtrace_heading]
        lines.concat(listed.map { |frame| text_frame(frame) })

        remaining = frames.length - listed.length
        lines << "  # … #{remaining} more #{pluralize(remaining, 'frame')}" if remaining.positive?

        lines.join("\n")
      end

      def backtrace_heading
        app_count = app_frames.length
        "### Backtrace (#{app_count} application #{pluralize(app_count, 'frame')} of #{frames.length})"
      end

      # App frames are indented, gem and core frames are commented out. Both prefixes are the same
      # width, so the paths line up and the app frames read as the signal they are.
      def text_frame(frame)
        prefix = safely(false) { frame.app? } ? "    " : "  # "
        label = safely(nil) { frame.label }
        location = "#{safely(nil) { frame.display_path }}:#{safely(nil) { frame.lineno }}"

        label ? "#{prefix}#{location}:in '#{label}'" : "#{prefix}#{location}"
      end

      def source_block
        frame = source_frame
        return nil unless frame

        excerpt = safely(nil) { frame.source }
        return nil unless excerpt

        lines = safely(nil) { excerpt.lines }
        return nil if lines.nil? || lines.empty?

        [
          "### Source: #{safely(nil) { frame.display_path }}:#{safely(nil) { frame.lineno }}",
          "```ruby",
          *excerpt_lines(excerpt, lines),
          "```"
        ].join("\n")
      end

      # The frame worth showing source for: the first application frame, since that is where the
      # developer can act. Falls back to the raise point when the stack never enters the app.
      def source_frame
        return @source_frame if defined?(@source_frame)

        @source_frame = app_frames.first || frames.first
      end

      def excerpt_lines(excerpt, lines)
        first_lineno = safely(1) { excerpt.first_lineno.to_i }
        highlight = safely(nil) { excerpt.highlight_lineno }
        width = (first_lineno + lines.length - 1).to_s.length

        lines.each_with_index.map { |line, index|
          lineno = first_lineno + index
          marker = lineno == highlight ? ">" : " "

          "#{marker} #{lineno.to_s.rjust(width)} | #{line}".rstrip
        }
      end

      def fallback_text
        "## #{safely('Exception') { class_name_of(exception) }}\n"
      end

      def pluralize(count, noun)
        count == 1 ? noun : "#{noun}s"
      end

      def compute_detailed_extras
        return [] unless exception.respond_to?(:detailed_message)

        detailed = exception.detailed_message(highlight: false)
        return [] unless detailed.is_a?(String)

        lines_beyond_message(detailed)
      rescue StandardError, ScriptError, SystemStackError
        []
      end

      def lines_beyond_message(detailed)
        known = message.lines.map(&:chomp)
        # `detailed_message` appends the exception class to the first line: strip it before
        # comparing, so the message itself is recognised and dropped.
        suffix = " (#{exception_class})"

        detailed.lines.filter_map { |line|
          text = line.chomp
          candidate = text.end_with?(suffix) ? text[0...-suffix.length] : text

          next if candidate.strip.empty?
          next if known.include?(candidate)

          text
        }
      end

      def compute_causes
        result = []
        current = exception

        MAX_CAUSES.times do
          current = current.cause
          break unless current.is_a?(Exception)
          break if current.equal?(exception)

          result << class_name_of(current)
        end

        result
      rescue StandardError
        []
      end

      def error_response
        return DEFAULT_ERROR_RESPONSE unless config.respond_to?(:render_error_responses)

        responses = config.render_error_responses
        return DEFAULT_ERROR_RESPONSE unless responses.respond_to?(:[])

        responses[exception_class] || DEFAULT_ERROR_RESPONSE
      end

      def filter_keys
        return [] unless config.respond_to?(:logger)

        logger = config.logger
        return [] unless logger.respond_to?(:filters)

        logger.filters || []
      rescue StandardError
        []
      end

      def class_name_of(object)
        klass = object.class
        name = klass.name

        name.nil? || name.empty? ? klass.to_s : name
      rescue StandardError
        "Exception"
      end

      # The same errors {Backtrace} rescues: `ScriptError` because `NotImplementedError` is one,
      # and `SystemStackError` for a runaway recursion in app code. Signals, `SystemExit`,
      # timeouts and `NoMemoryError` are not rescued: those must still stop the request.
      def safely(fallback)
        yield
      rescue StandardError, ScriptError, SystemStackError
        fallback
      end
    end
  end
end
