# frozen_string_literal: true

require "rack/utils"
require "securerandom"

require_relative "../diagnostics"
require_relative "safety"

module Hanami
  module Webconsole
    # The view model for a single error.
    #
    # Nothing on this object raises, otherwise the error page cannot render at all, so every value
    # degrades to something safe.
    #
    # @api private
    class ErrorPage
      include Safety

      # Status used when the exception maps to nothing in `config.render_error_responses`.
      DEFAULT_ERROR_RESPONSE = :internal_server_error

      # Status code used as a safe fallback for {#status}.
      DEFAULT_STATUS = 500

      attr_reader :exception

      attr_reader :env

      attr_reader :config

      # The random id under which this page is stored in the {Registry}.
      #
      # @return [String]
      attr_reader :id

      # @param exception [Exception]
      # @param env [Hash] the Rack env
      # @param config [Hanami::Config] the app config
      # @param bindings [Array<Binding>, nil] bindings aligned to the exception's backtrace
      # @param slice [Hanami::Slice, nil] the slice the middleware belongs to, for diagnostics
      def initialize(exception:, env:, config:, bindings: nil, slice: nil)
        @exception = exception
        @env = env || {}
        @config = config
        @id = SecureRandom.hex(8)
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

      # Returns the diagnostic for the exception, wrapped so it's safe to use, or nil if no
      # diagnostic applies.
      #
      # This is built only once per page. Since the page is kept in the registry, this means the
      # run endpoint runs the fix on the same diagnostic that rendered the page.
      #
      # @return [Hanami::Diagnostics::Wrapper, nil]
      def diagnostic
        return @diagnostic if defined?(@diagnostic)

        @diagnostic = safely(nil) {
          Hanami::Diagnostics::Registry.for(exception, Hanami::Diagnostics::Context.new(slice: @slice))
        }
      end

      # Class names of the exception's causes, outermost cause last.
      #
      # @return [Array<String>]
      def causes
        @causes ||= Hanami::Diagnostics::Causes.of(exception).map { |cause| class_name_of(cause) }
      end

      # @return [Backtrace]
      def backtrace
        @backtrace ||= Backtrace.new(exception:, root:, bindings: @bindings)
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
        @request ||= RequestContext.new(env:, filters:)
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

      private

      def compute_detailed_extras
        return [] unless exception.respond_to?(:detailed_message)

        detailed = exception.detailed_message(highlight: false)
        return [] unless detailed.is_a?(String)

        lines_beyond_message(detailed)
      rescue *Safety::ERRORS
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
    end
  end
end
