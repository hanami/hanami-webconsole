# frozen_string_literal: true

require "rack/utils"
require "securerandom"

require_relative "presenters"

module Hanami
  module Webconsole
    # The view model for a single error.
    #
    # Everything the page shows is reachable from here, and everything here is already computed:
    # the template asks questions, it does not do work. Nothing on this object raises — an error
    # page that fails to render leaves the developer with nothing at all, so every value degrades
    # to something safe instead.
    #
    # @api private
    # @since 3.1.0
    class ErrorPage
      # Status used when the exception maps to nothing in `config.render_error_responses`.
      #
      # @api private
      # @since 3.1.0
      DEFAULT_ERROR_RESPONSE = :internal_server_error

      # @api private
      # @since 3.1.0
      DEFAULT_STATUS = 500

      # @api private
      # @since 3.1.0
      NOT_FOUND_STATUS = 404

      # Cause chains are walked, not trusted: stop after this many.
      #
      # @api private
      # @since 3.1.0
      MAX_CAUSES = 10
      private_constant :MAX_CAUSES

      # Frames listed by {#to_text}, before truncating.
      #
      # @api private
      # @since 3.1.0
      MAX_TEXT_FRAMES = 25
      private_constant :MAX_TEXT_FRAMES

      # @api private
      # @since 3.1.0
      attr_reader :exception

      # @api private
      # @since 3.1.0
      attr_reader :env

      # @api private
      # @since 3.1.0
      attr_reader :config

      # The id under which this page is stored in the {Registry}.
      #
      # Stamped with the generation that created it, so that a page outliving a code reload can be
      # recognised and dropped rather than evaluated against unloaded constants.
      #
      # @return [String]
      #
      # @api private
      # @since 3.1.0
      attr_reader :id

      # @return [Integer]
      #
      # @api private
      # @since 3.1.0
      attr_reader :generation

      # Builds a page id for the given generation.
      #
      # @return [String]
      #
      # @api private
      # @since 3.1.0
      def self.generate_id(generation = Webconsole.generation)
        "#{generation}-#{SecureRandom.hex(8)}"
      end

      # @param exception [Exception]
      # @param env [Hash] the Rack env
      # @param config [Hanami::Config] the app config, or anything answering `render_error_responses`,
      #   `root` and `logger`
      # @param id [String, nil]
      # @param generation [Integer]
      # @param bindings [Array<Binding>, nil] bindings aligned to the exception's backtrace
      #
      # @api private
      # @since 3.1.0
      def initialize(exception:, env:, config:, id: nil, generation: Webconsole.generation, bindings: nil)
        @exception = exception
        @env = env || {}
        @config = config
        @generation = generation
        @id = id || self.class.generate_id(generation)
        @bindings = bindings
      end

      # @return [String]
      #
      # @api private
      # @since 3.1.0
      def exception_class
        @exception_class ||= class_name_of(exception)
      end

      # @return [String]
      #
      # @api private
      # @since 3.1.0
      def message
        @message ||= safely("") { exception.message.to_s }
      end

      # A longer explanation the error may offer, shown under the headline.
      #
      # Optional, and only meaningful alongside resolutions: when an error can explain itself,
      # `#message` reads as the headline and this is the paragraph beneath it.
      #
      # @return [String, nil]
      #
      # @api private
      # @since 3.1.0
      def detail
        return @detail if defined?(@detail)

        @detail = safely(nil) {
          next nil unless exception.respond_to?(:detail)

          value = exception.detail
          value.nil? || value.to_s.empty? ? nil : value.to_s
        }
      end

      # The lines `detailed_message` adds beyond `message`.
      #
      # On Ruby 3.1+ this is where `did_you_mean`'s suggestions and `error_highlight`'s caret live.
      # They are the most immediately useful thing about a `NoMethodError`, and they are not part
      # of `message`, so they are diffed out of `detailed_message` rather than recomputed.
      #
      # @return [Array<String>]
      #
      # @api private
      # @since 3.1.0
      def detailed_extras
        @detailed_extras ||= compute_detailed_extras
      end

      # The response status for this exception, per `config.render_error_responses`.
      #
      # @return [Integer]
      #
      # @api private
      # @since 3.1.0
      def status
        @status ||= safely(DEFAULT_STATUS) { Rack::Utils.status_code(error_response) }
      end

      # Which of the page's three shapes to render.
      #
      # @return [Symbol] `:not_found`, `:actionable` or `:crash`
      #
      # @api private
      # @since 3.1.0
      def severity
        return :not_found if status == NOT_FOUND_STATUS
        return :actionable if presenter || resolutions.any?

        :crash
      end

      # Steps the error itself offers for fixing it.
      #
      # An error that knows how to fix itself outranks a generic crash page: the backtrace
      # collapses and the resolutions lead.
      #
      # @return [Array<Resolution>]
      #
      # @api private
      # @since 3.1.0
      def resolutions
        @resolutions ||= safely([]) { Resolution.for(exception) }
      end

      # Class names of the exception's causes, outermost cause last.
      #
      # @return [Array<String>]
      #
      # @api private
      # @since 3.1.0
      def causes
        @causes ||= compute_causes
      end

      # @return [Backtrace]
      #
      # @api private
      # @since 3.1.0
      def backtrace
        @backtrace ||= Backtrace.new(exception: exception, root: root, bindings: @bindings)
      end

      # @return [Array<Frame>]
      #
      # @api private
      # @since 3.1.0
      def frames
        @frames ||= safely([]) { backtrace.frames }
      end

      # @return [Array<Frame>]
      #
      # @api private
      # @since 3.1.0
      def app_frames
        @app_frames ||= safely([]) { backtrace.app_frames }
      end

      # @return [RequestContext]
      #
      # @api private
      # @since 3.1.0
      def request
        @request ||= RequestContext.new(env: env, filters: filters)
      end

      # @return [Filters]
      #
      # @api private
      # @since 3.1.0
      def filters
        @filters ||= Filters.new(filter_keys)
      end

      # The app root, used to classify frames.
      #
      # @return [String]
      #
      # @api private
      # @since 3.1.0
      def root
        @root ||= safely(Dir.pwd) {
          config.respond_to?(:root) ? config.root.to_s : Dir.pwd
        }
      end

      # The presenter for this exception, when one is registered.
      #
      # @return [Presenters::Base, nil]
      #
      # @api private
      # @since 3.1.0
      def presenter
        return @presenter if defined?(@presenter)

        @presenter = Presenters.for(exception)
      end

      # The whole error as Markdown.
      #
      # This backs both the "Copy as text" button and the `text/plain` response, so it has two
      # audiences: a GitHub issue or an LLM prompt, and a terminal. It is a deliverable, not a
      # debug dump — app frames are indented and gem frames are commented out, so the shape of the
      # stack is readable at a glance.
      #
      # @return [String]
      #
      # @api private
      # @since 3.1.0
      def to_text
        safely(fallback_text) { text_blocks.compact.join("\n\n") + "\n" }
      end

      private

      def text_blocks
        [
          "## #{exception_class}",
          message.empty? ? nil : message,
          metadata_block,
          extras_block,
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
      rescue Exception # rubocop:disable Lint/RescueException
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

      def safely(fallback)
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        fallback
      end
    end
  end
end
