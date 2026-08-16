# frozen_string_literal: true

module Hanami
  module Webconsole
    # Bounded, generation-scoped store of error pages.
    #
    # An error page is stored so that its interactive parts — per-frame variables and the console —
    # can address it by id on subsequent requests. Two properties matter:
    #
    # - **Bounded.** Pages retain bindings, which retain everything reachable from them. Only the
    #   most recently used pages are kept, so several error tabs can stay interactive at once
    #   without the process growing without limit.
    # - **Generation-scoped.** A page's bindings refer to constants that code reloading has since
    #   unloaded. Evaluating against them would silently use stale classes, so a page from an older
    #   generation is treated as unknown, and the console reports the session as expired.
    #
    # Thread-safe: a development server handles requests concurrently.
    #
    # @api private
    # @since 3.1.0
    class Registry
      # @api private
      # @since 3.1.0
      DEFAULT_MAX = 16

      # @api private
      # @since 3.1.0
      def initialize(max: DEFAULT_MAX)
        @max = [max.to_i, 0].max
        @pages = {}
        @mutex = Mutex.new
      end

      # Stores a page, evicting stale and least recently used entries.
      #
      # @param page [ErrorPage]
      #
      # @return [String] the page id
      #
      # @api private
      # @since 3.1.0
      def put(page)
        @mutex.synchronize do
          @pages.delete(page.id)
          @pages[page.id] = page

          drop_stale
          drop_overflow
        end

        page.id
      end

      # Returns the page for the given id, or nil.
      #
      # Returns nil both for an unknown id and for a page from a previous generation. Callers
      # cannot distinguish the two, and should not: from the browser's point of view they are the
      # same "this page is no longer live, refresh" condition.
      #
      # @param id [String, nil]
      #
      # @return [ErrorPage, nil]
      #
      # @api private
      # @since 3.1.0
      def fetch(id)
        @mutex.synchronize do
          page = @pages[id]
          next nil unless page

          @pages.delete(id)

          next nil unless current?(page)

          # Reinsert, so that the most recently used page is evicted last.
          @pages[id] = page
        end
      end

      # Drops every page from a previous generation.
      #
      # @return [self]
      #
      # @api private
      # @since 3.1.0
      def sweep!
        @mutex.synchronize { drop_stale }
        self
      end

      # Number of pages currently held.
      #
      # @return [Integer]
      #
      # @api private
      # @since 3.1.0
      def size
        @mutex.synchronize { @pages.size }
      end

      private

      def current?(page)
        page.generation == Webconsole.generation
      end

      def drop_stale
        @pages.delete_if { |_id, page| !current?(page) }
      end

      def drop_overflow
        @pages.shift while @pages.size > @max
      end
    end
  end
end
