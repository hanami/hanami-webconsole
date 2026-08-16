# frozen_string_literal: true

module Hanami
  module Webconsole
    # Reads source files from disk and hands back the small window of lines shown around a
    # backtrace frame.
    #
    # The web console runs inside a long-lived development process, so reads are cached, keyed by
    # path *and* mtime: editing a file invalidates its entry without any explicit reload hook. The
    # cache is bounded, since a big app can touch many files over a long session.
    #
    # Nothing here raises. A source file may be deleted, unreadable, binary, or enormous; in every
    # one of those cases the answer is `nil` and the page renders a "source unavailable" state
    # instead of failing while it tries to explain another failure.
    #
    # @api private
    # @since 3.1.0
    module SourceFile
      # A window of lines around a highlighted line.
      #
      # `lines` have no trailing newlines. `first_lineno` is the 1-based number of `lines.first`,
      # so line `n` is `lines[n - first_lineno]`.
      #
      # @api private
      # @since 3.1.0
      Excerpt = Struct.new(:path, :first_lineno, :lines, :highlight_lineno, keyword_init: true)

      # Largest file we will read. Anything bigger is almost certainly not hand-written source.
      #
      # @api private
      # @since 3.1.0
      MAX_SIZE = 2 * 1024 * 1024

      # Maximum number of files held in the cache.
      #
      # @api private
      # @since 3.1.0
      CACHE_LIMIT = 64

      # Number of lines shown either side of the highlighted line.
      #
      # @api private
      # @since 3.1.0
      DEFAULT_CONTEXT = 7

      @cache = {}
      @mutex = Mutex.new

      class << self
        # Returns the lines around `around` in the file at `path`.
        #
        # @param path [String] absolute path to the file
        # @param around [Integer] 1-based line number to highlight
        # @param context [Integer] number of lines to include either side
        #
        # @return [Excerpt, nil] nil when the file is missing, unreadable, binary, too large, or
        #   the requested line lies outside it
        #
        # @api private
        # @since 3.1.0
        def read(path, around:, context: DEFAULT_CONTEXT)
          path = path.to_s
          around = Integer(around)
          context = Integer(context)
          return nil if path.empty? || around < 1 || context.negative?

          lines = lines_for(path)
          return nil if lines.nil? || lines.empty?

          first = [around - context, 1].max
          last = [around + context, lines.length].min
          return nil if first > last

          Excerpt.new(
            path: path,
            first_lineno: first,
            lines: lines[(first - 1)..(last - 1)],
            highlight_lineno: around
          )
        rescue StandardError, SystemStackError
          nil
        end

        private

        # @api private
        # @since 3.1.0
        def lines_for(path)
          stat = File.stat(path)
          return nil unless stat.file?
          return nil if stat.size > MAX_SIZE

          key = [path, stat.mtime, stat.size]
          cached = fetch(key)
          return cached if cached

          lines = load(path)
          return nil if lines.nil?

          store(key, lines)
          lines
        rescue StandardError
          nil
        end

        # @api private
        # @since 3.1.0
        def fetch(key)
          @mutex.synchronize do
            lines = @cache.delete(key)
            @cache[key] = lines if lines
            lines
          end
        end

        # @api private
        # @since 3.1.0
        def store(key, lines)
          @mutex.synchronize do
            @cache.delete_if { |(cached_path, _, _), _| cached_path == key.first }
            @cache[key] = lines
            @cache.shift while @cache.size > CACHE_LIMIT
          end
        end

        # @api private
        # @since 3.1.0
        def load(path)
          content = File.read(path, mode: "rb")
          return nil if content.include?("\0")

          content.force_encoding(Encoding::UTF_8)
          return nil unless content.valid_encoding?

          content.lines.map(&:chomp)
        rescue StandardError
          nil
        end
      end
    end
  end
end
