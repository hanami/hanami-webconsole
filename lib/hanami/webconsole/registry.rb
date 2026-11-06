# frozen_string_literal: true

module Hanami
  module Webconsole
    # Bounded store of error pages.
    #
    # An error page is stored so that its interactive parts — per-frame variables and the console —
    # can address it by id on subsequent requests. Pages retain bindings, which retain everything
    # reachable from them, so only the most recently used pages are kept. Several error tabs can
    # stay interactive at once without the process growing without limit.
    #
    # Each {Middleware} has its own registry, so a registry lives exactly as long as its middleware.
    # This is what stops a page from outliving its code. A page's bindings refer to the code that
    # was loaded when it was rendered, and evaluating against them after a reload would silently
    # use unloaded classes. But a reload never leaves a registry in place:
    #
    # - Hanami builds the app's middleware stack again after every reload (`Slice#reload` clears
    #   the slice's Rack app), so the app's pages go away with the old middleware.
    # - hanami-reloader renders a failed reload with its own middleware, which it builds anew for
    #   each failed reload and drops after a successful one.
    #
    # A request for a page that went away finds no page, and the console reports the session as
    # expired. If either of the above stops being true, pages will outlive their code.
    #
    # Thread-safe: a development server handles requests concurrently.
    #
    # @api private
    class Registry
      DEFAULT_MAX = 16

      def initialize(max: DEFAULT_MAX)
        @max = [max.to_i, 0].max
        @pages = {}
        @mutex = Mutex.new
      end

      # Stores a page, evicting the least recently used pages beyond the bound.
      #
      # @param page [ErrorPage]
      #
      # @return [String] the page id
      def put(page)
        @mutex.synchronize do
          @pages.delete(page.id)
          @pages[page.id] = page

          @pages.shift while @pages.size > @max
        end

        page.id
      end

      # Returns the page for the given id, or nil if there's no such page.
      #
      # @param id [String, nil]
      #
      # @return [ErrorPage, nil]
      def fetch(id)
        @mutex.synchronize do
          page = @pages.delete(id)
          next nil unless page

          # Reinsert, so that the most recently used page is evicted last.
          @pages[id] = page
        end
      end

      # Number of pages currently held.
      #
      # @return [Integer]
      def size
        @mutex.synchronize { @pages.size }
      end
    end
  end
end
