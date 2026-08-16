# frozen_string_literal: true

require_relative "frame"

module Hanami
  module Webconsole
    # An exception's backtrace, turned into {Frame}s.
    #
    # `Exception#backtrace_locations` is preferred: it is structured, and it keeps the absolute
    # path even when the file was required relatively. It is not always there, though —
    # exceptions built by hand with `set_backtrace`, exceptions crossing a marshalling boundary,
    # and some exceptions raised from C have strings and nothing else. Those are parsed instead.
    #
    # Nothing here raises. An error page that crashes while formatting a backtrace tells the
    # developer nothing at all, so every failure degrades to fewer frames, or none.
    #
    # @api private
    # @since 3.1.0
    class Backtrace
      # Stands in for a `Thread::Backtrace::Location` when only backtrace strings are available.
      #
      # @api private
      # @since 3.1.0
      Location = Struct.new(:path, :lineno, :label, keyword_init: true)

      # Matches a backtrace line: `path:12:in 'Foo#bar'`, or `path:12`.
      #
      # Ruby 3.4 quotes the label as `'Foo#bar'` and includes the class; earlier versions wrote
      # `` `bar' `` with a backtick, so both openers are accepted. `path` is greedy so that the
      # *last* `:<digits>` is taken as the line number, which keeps Windows drive letters and
      # any other colons in the path intact.
      #
      # @api private
      # @since 3.1.0
      LINE = /\A(?<path>.*):(?<lineno>\d+)(?::in\s+[`'](?<label>.*)')?\z/

      # @api private
      # @since 3.1.0
      EMPTY_FRAMES = [].freeze

      # @return [Exception]
      #
      # @api private
      # @since 3.1.0
      attr_reader :exception

      # @return [String]
      #
      # @api private
      # @since 3.1.0
      attr_reader :root

      # @return [Array<Binding>, nil]
      #
      # @api private
      # @since 3.1.0
      attr_reader :bindings

      # @param exception [Exception]
      # @param root [String] the app root, used to classify frames
      # @param bindings [Array<Binding>, nil] aligned index-for-index with the backtrace
      #
      # @api private
      # @since 3.1.0
      def initialize(exception:, root:, bindings: nil)
        @exception = exception
        @root = root.to_s
        @bindings = bindings
      end

      # All frames, in caller order: the raise point first.
      #
      # @return [Array<Frame>]
      #
      # @api private
      # @since 3.1.0
      def frames
        @frames ||= build_frames
      end

      # The frames belonging to the application, which is what the page opens on.
      #
      # @return [Array<Frame>]
      #
      # @api private
      # @since 3.1.0
      def app_frames
        @app_frames ||= frames.select(&:app?)
      end

      private

      # @api private
      # @since 3.1.0
      def build_frames
        locations = backtrace_locations
        locations = parsed_locations if locations.nil? || locations.empty?
        return EMPTY_FRAMES if locations.nil? || locations.empty?

        locations.each_with_index.map { |location, index|
          Frame.new(location: location, root: root, binding: binding_at(index))
        }
      rescue StandardError, ScriptError, SystemStackError
        EMPTY_FRAMES
      end

      # @api private
      # @since 3.1.0
      def backtrace_locations
        return nil unless exception.respond_to?(:backtrace_locations)

        locations = exception.backtrace_locations
        return nil unless locations.is_a?(Array)

        locations.compact
      rescue StandardError
        nil
      end

      # @api private
      # @since 3.1.0
      def parsed_locations
        return nil unless exception.respond_to?(:backtrace)

        lines = exception.backtrace
        return nil unless lines.is_a?(Array)

        lines.filter_map { |line| parse(line) }
      rescue StandardError
        nil
      end

      # An unparseable line still becomes a frame: it is more useful shown verbatim, classified as
      # `:core`, than silently dropped.
      #
      # @api private
      # @since 3.1.0
      def parse(line)
        line = line.to_s
        return nil if line.empty?

        match = LINE.match(line)
        return Location.new(path: line, lineno: 0, label: "") unless match

        Location.new(path: match[:path], lineno: match[:lineno].to_i, label: match[:label].to_s)
      rescue StandardError
        nil
      end

      # @api private
      # @since 3.1.0
      def binding_at(index)
        return nil unless bindings.is_a?(Array)

        candidate = bindings[index]
        candidate.is_a?(Binding) ? candidate : nil
      end
    end
  end
end
