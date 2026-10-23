# frozen_string_literal: true

require_relative "source_file"

module Hanami
  module Webconsole
    # A single name/value pair shown on the error page.
    #
    # Every attribute is a String. `value` has already been through {Inspector}, so templates can
    # render it without any further processing, and never touch the underlying object.
    #
    # @api private
    Variable = Struct.new(:name, :class_name, :value, keyword_init: true)

    # One entry in a backtrace, together with everything the page shows for it: where it points,
    # whether it belongs to the app, the surrounding source, and (when a binding was captured)
    # the local variables and receiver at that point.
    #
    # Frames are built for every backtrace entry but most are never rendered, so all the expensive
    # work — reading source, inspecting variables, stat-ing the path — is deferred until asked
    # for, and memoized once done.
    #
    # NOTE: {Inspector} is referenced lazily, at call time, and only from {#locals},
    # {#instance_vars} and {#receiver_inspect}.
    #
    # @api private
    class Frame
      EMPTY_VARIABLES = [].freeze

      # Path segment that separates an installed gem's directory from the rest of a gem home.
      GEMS_SEGMENT = "/gems/"

      # Matches a path that lives inside an installed gem, wherever that gem home happens to be.
      # Covers RubyGems homes, `bundle config path` targets, and bundler's git gem checkouts.
      GEMS_DIRECTORY = %r{/gems/[^/]+/}

      # Prefixes used by paths that are not files at all: `<internal:kernel>`, `(eval)`, `(irb)`.
      VIRTUAL_PREFIXES = ["<", "("].freeze

      class << self
        # Directories that hold installed gems.
        #
        # Memoized: this is stable for the life of the process, and it would otherwise be
        # recomputed for every frame of every backtrace.
        #
        # @return [Array<String>]
        def gem_paths
          @gem_paths ||= begin
            paths = Array(Gem.path)
            paths += [Gem.default_dir] if Gem.respond_to?(:default_dir)
            paths << Bundler.bundle_path if defined?(Bundler) && Bundler.respond_to?(:bundle_path)
            paths.compact.map { |path| path.to_s.chomp(File::SEPARATOR) }.reject(&:empty?).uniq
          rescue StandardError
            []
          end
        end
      end

      # @return [String] absolute where the backtrace gave us one
      attr_reader :path

      # @return [Integer] 0 when the backtrace did not give us a line
      attr_reader :lineno

      # @return [String] e.g. "Bookshelf::Repositories::BookRepo#find_with_reviews"
      attr_reader :label

      # @return [Binding, nil]
      attr_reader :binding

      # @return [String] the app root this frame was classified against
      attr_reader :root

      # @param location [Thread::Backtrace::Location] or any object answering #path, #lineno and
      #   #label
      # @param root [String] the app root, used to classify the frame
      # @param binding [Binding, nil]
      def initialize(location:, root:, binding: nil)
        @root = root.to_s.chomp(File::SEPARATOR)
        @binding = binding
        @path = extract_path(location)
        @lineno = extract_lineno(location)
        @label = extract_label(location)
      end

      # Where this frame's code came from.
      #
      # `:app` is code the developer wrote, `:gem` is a dependency, and `:core` is everything
      # else: Ruby itself, C frames, `eval`'d code, and paths that no longer exist on disk.
      #
      # @return [Symbol] :app, :gem or :core
      def kind
        @kind ||= detect_kind
      end

      # @return [Boolean]
      def app?
        kind == :app
      end

      # The path as shown on the page: relative to the app root for app frames, and relative to
      # the gem home for gem frames, so a frame reads `rack-3.1.8/lib/rack/method_override.rb`
      # rather than a hundred characters of installation prefix.
      #
      # @return [String]
      def display_path
        @display_path ||= detect_display_path
      end

      # @return [SourceFile::Excerpt, nil] nil when the source cannot be read
      def source
        return @source if defined?(@source)

        @source = SourceFile.read(path, around: lineno)
      end

      # @return [Array<Variable>] empty when no binding was captured for this frame
      def locals
        @locals ||= build_locals
      end

      # @return [Array<Variable>] empty when no binding was captured for this frame
      def instance_vars
        @instance_vars ||= build_instance_vars
      end

      # @return [String, nil] safe-inspected `self`, nil when no binding was captured
      def receiver_inspect
        return @receiver_inspect if defined?(@receiver_inspect)

        @receiver_inspect = build_receiver_inspect
      end

      private

      def extract_path(location)
        absolute = location.absolute_path if location.respond_to?(:absolute_path)
        (absolute || location.path).to_s
      rescue StandardError
        ""
      end

      def extract_lineno(location)
        Integer(location.lineno)
      rescue StandardError
        0
      end

      def extract_label(location)
        location.label.to_s
      rescue StandardError
        ""
      end

      def detect_kind
        return :core if path.empty? || virtual_path?
        return :core unless file?
        return :app if app_path?
        return :gem if gem_path?

        :core
      end

      def virtual_path?
        VIRTUAL_PREFIXES.any? { |prefix| path.start_with?(prefix) }
      end

      def file?
        File.file?(path)
      rescue StandardError
        false
      end

      # Vendored dependencies live under the app root but are not the developer's code, so they
      # are excluded here and picked up by the gem check instead.
      def app_path?
        return false if root.empty?

        under?(path, root) && !under?(path, "#{root}/vendor")
      end

      def gem_path?
        return true if GEMS_DIRECTORY.match?(path)

        self.class.gem_paths.any? { |directory| under?(path, directory) }
      end

      def under?(candidate, directory)
        return false if directory.empty?

        candidate.start_with?("#{directory}#{File::SEPARATOR}")
      end

      def detect_display_path
        case kind
        when :app then strip_prefix(path, root)
        when :gem then gem_display_path
        else path
        end
      end

      def gem_display_path
        index = path.rindex(GEMS_SEGMENT)
        return path[(index + GEMS_SEGMENT.length)..] if index

        directory = self.class.gem_paths.find { |candidate| under?(path, candidate) }
        directory ? strip_prefix(path, directory) : path
      end

      def strip_prefix(value, directory)
        return value unless under?(value, directory)

        value[(directory.length + 1)..] || value
      end

      def build_locals
        return EMPTY_VARIABLES unless binding

        binding.local_variables.filter_map { |name|
          variable(name, binding.local_variable_get(name))
        }
      rescue StandardError, ScriptError, SystemStackError
        EMPTY_VARIABLES
      end

      def build_instance_vars
        return EMPTY_VARIABLES unless binding

        receiver = binding.receiver
        receiver.instance_variables.filter_map { |name|
          variable(name, receiver.instance_variable_get(name))
        }
      rescue StandardError, ScriptError, SystemStackError
        EMPTY_VARIABLES
      end

      def build_receiver_inspect
        return nil unless binding

        Inspector.call(binding.receiver).to_s
      rescue StandardError, ScriptError, SystemStackError
        nil
      end

      # A single unreadable value must not take the whole panel down with it, so failures here
      # drop the variable rather than propagate.
      def variable(name, value)
        Variable.new(
          name: name.to_s,
          class_name: Inspector.class_name(value).to_s,
          value: Inspector.call(value).to_s
        )
      rescue StandardError, ScriptError, SystemStackError
        nil
      end
    end
  end
end
