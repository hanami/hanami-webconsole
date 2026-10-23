# frozen_string_literal: true

require "did_you_mean/levenshtein"

module Hanami
  module Webconsole
    module Presenters
      # Presenter for `Hanami::Router::NotFoundError`.
      #
      # A 404 in development is almost always a typo or a route that was never added, so the page
      # answers the two questions the developer actually has: what did I ask for, and what could I
      # have asked for. The routes the app does have are listed in a panel, the closest matches are
      # offered as "Did you mean" chips, and the row for each of those is highlighted in the list.
      #
      # The routes come from the slice carried by the error (hanami 3.1+), whose router answers
      # `#routes` (hanami-router 3.1+). Against an older hanami, or an error raised outside a
      # slice, there is nothing to list and the page falls back to the message alone.
      #
      # @api private
      # @since 3.1.0
      class NotFound < Base
        # Routes listed before truncating.
        #
        # An app with more routes than this is not going to be read off the page, and the panel
        # has a filter box for finding one by name.
        #
        # @api private
        # @since 3.1.0
        MAX_ROUTES = 200

        # @api private
        # @since 3.1.0
        MAX_SUGGESTIONS = 3

        # HTTP methods with a router DSL method of their own, for {#snippet}. HEAD is absent
        # deliberately: the router defines it alongside every GET.
        #
        # @api private
        # @since 3.1.0
        SNIPPET_VERBS = {
          "GET" => "get", "HEAD" => "get", "POST" => "post", "PATCH" => "patch",
          "PUT" => "put", "DELETE" => "delete", "OPTIONS" => "options", "TRACE" => "trace"
        }.freeze

        # @api private
        # @since 3.1.0
        def headline
          return "No route matched this request" if request_summary.empty?

          "No route matched #{request_summary}"
        end

        # @api private
        # @since 3.1.0
        def lede
          return nil unless router

          return "This app has no routes yet. Add one in config/routes.rb." if routes.empty?

          # Counts what the panel lists, so the two numbers on the page agree.
          count = listed_routes.length
          return "The router has 1 route, and it did not match this request." if count == 1

          "The router has #{count} routes, and none of them matched this request."
        end

        # The routes the developer probably meant, as chips under the message.
        #
        # @return [Array<String>]
        #
        # @api private
        # @since 3.1.0
        def suggestions
          @suggestions ||= near_paths.first(MAX_SUGGESTIONS)
        end

        # A route definition to paste, when there is nothing close enough to suggest.
        #
        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def snippet
          return nil unless snippet?

          %(#{SNIPPET_VERBS.fetch(verb)} "#{path}", to: "...")
        end

        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def note
          return nil unless snippet?

          "Add it to `config/routes.rb`."
        end

        # @return [Array<Array>]
        #
        # @api private
        # @since 3.1.0
        def context_panels
          listed = listable_routes
          return [] if listed.empty?

          [[panel_title(listed), listed.map { |route| row_for(route) }]]
        end

        private

        # The router of the slice that raised, when it can list its routes.
        #
        # @return [Hanami::Router, nil]
        def router
          return @router if defined?(@router)

          @router = safely(nil) {
            next nil unless exception.respond_to?(:slice)

            router = exception.slice&.router
            router.respond_to?(:routes) ? router : nil
          }
        end

        # @return [Array<Hanami::Router::Route>]
        def routes
          @routes ||= safely([]) { router ? Array(router.routes) : [] }
        end

        # HEAD routes are generated for every GET, so listing them doubles the panel with rows
        # nobody defined. `hanami routes` hides them for the same reason.
        def listable_routes
          @listable_routes ||= listed_routes.first(MAX_ROUTES)
        end

        def listed_routes
          @listed_routes ||= routes.reject { |route| head?(route) && verb != "HEAD" }
        end

        # Says so when the list is truncated, rather than showing a count that disagrees with
        # `hanami routes`.
        def panel_title(listed)
          total = listed_routes.length

          listed.length < total ? "Routes (#{listed.length} of #{total})" : "Routes (#{total})"
        end

        def row_for(route)
          name = safely("") { "#{route.http_method} #{route.path}".strip }

          [name, endpoint_for(route), false, near?(route)]
        end

        # Mirrors the columns of `hanami routes`: the endpoint, then the route name and
        # constraints when it has them.
        def endpoint_for(route)
          safely("") {
            parts = [route.inspect_to.to_s]
            parts << "as #{route.inspect_as}" if route.as?
            parts << "(#{route.inspect_constraints})" if route.constraints?
            parts.join(" ")
          }
        end

        def near?(route)
          safely(false) {
            next false if head?(route)

            near_paths.include?(route.path) || (route.path == path && route.http_method != verb)
          }
        end

        # Returns the route patterns closest to the requested path, closest first.
        #
        # The request is a concrete path, but routes are patterns. Compared as plain strings,
        # `/bookz/1` is four single-character changes away from `/books/:id`, even though it has
        # only one typo. So we first project the request path onto each pattern (see {#project}),
        # which turns `/bookz/1` into `/bookz/:id`, then compare those two by edit distance (the
        # number of single-character changes, see {#near_match}).
        #
        # We don't use `DidYouMean::SpellChecker` here, since it checks a _single_ input string
        # against a list of words. We have no single input: the string we compare depends on the
        # pattern it's projected onto (e.g. `/bookz/1` becomes `/bookz/:id` for `/books/:id`, but
        # `/bookz/:user_id` for `/users/:user_id`). Doing it the other way around (filling each
        # pattern's params from the request path, so the input stays as `/bookz/1`) doesn't work
        # either: a long param value (e.g. a UUID) ends up in every filled pattern, and makes
        # unrelated routes look close.
        #
        # If the request path projects _exactly_ onto a pattern, then it has the right shape but
        # failed one of the route's constraints. This gives a distance of zero, which makes it the
        # best suggestion.
        #
        # Never suggests the root path: almost any short path is a character or two away from it.
        def near_paths
          @near_paths ||= safely([]) {
            routes
              # Include only paths reachable by the same HTTP method
              .select { |route| route.http_method == verb || route.http_method == "*" }
              # A route path is a _pattern_, like `/books/:id`
              .map(&:path)
              .uniq
              .filter_map { |pattern| near_match(pattern) }
              .sort_by.with_index { |(_pattern, distance), index| [distance, index] }
              .map(&:first)
          }
        end

        # @return [Array(String, Integer), nil] the pattern and its distance, when it is close
        def near_match(pattern)
          return if path.empty? || pattern == "/"

          projected = project(path, pattern)
          distance = ::DidYouMean::Levenshtein.distance(pattern, projected)

          # Consider a pattern close enough if it's within a quarter of the path's length in
          # single-character changes, rounded up. This is the same limit `did_you_mean` uses for
          # mistyped method names. The limit grows with the length (longer paths have room for more
          # typos), and rounding up allows at least one typo, even for very short paths.
          #
          # Count only the static text towards the length, not param or glob names like `:id` or
          # `*path`. These are the same on both sides, so they can't hold a typo, and counting them
          # would let unrelated patterns through (e.g. `/orders/<uuid>` would match `/files/*path`).
          static_length = projected.gsub(%r{(?<=/)[:*][^/]*}, "").length
          [pattern, distance] if distance <= (static_length * 0.25).ceil
        end

        # Rewrites the request path to the shape of the pattern. Segments captured by a `:param` in
        # the pattern take the param's name, and a `*glob` takes the rest of the path:
        #
        #   project("/bookz/1", "/books/:id")                       # => "/bookz/:id"
        #   project("/authors/1/book", "/authors/:author_id/books") # => "/authors/:author_id/book"
        #   project("/filez/a/b.txt", "/files/*path")               # => "/filez/*path"
        #   project("/bookz/1", "/users/:id")                       # => "/bookz/:id"
        #
        # After this, only the real differences remain. The first three are now a single-character
        # change away from their patterns. The last is still five away from `/users/:id`, above the
        # limit for a path this long (see {#near_match}), so it's never suggested.
        #
        # If the segment counts differ, or the glob has nothing to take, then the path has no shape
        # in common with the pattern, and we return it unchanged:
        #
        #   project("/books/1", "/books")                           # => "/books/1"
        #   project("/files", "/files/*path")                       # => "/files"
        def project(path, pattern)
          segments = path.split("/", -1)
          pattern_segments = pattern.split("/", -1)

          if (glob = pattern_segments.index { |segment| segment.start_with?("*") })
            return path if segments.length <= glob

            segments = segments.first(glob) + [pattern_segments[glob]]
            pattern_segments = pattern_segments.first(glob + 1)
          end

          return path unless segments.length == pattern_segments.length

          segments.zip(pattern_segments).map { |segment, pattern_segment|
            pattern_segment.start_with?(":") ? pattern_segment : segment
          }.join("/")
        end

        def snippet?
          !path.empty? && SNIPPET_VERBS.key?(verb) && suggestions.empty?
        end

        def head?(route)
          safely(false) { route.head? }
        end

        def request_summary
          @request_summary ||= "#{verb} #{path}".strip
        end

        def verb
          @verb ||= env_value("REQUEST_METHOD")
        end

        def path
          @path ||= env_value("PATH_INFO")
        end

        def env_value(key)
          safely("") {
            next "" unless exception.respond_to?(:env)

            exception.env.to_h[key].to_s
          }
        end

        # Nothing here may raise: this presenter runs while a page is being built for an error
        # that has already happened, and a presenter that blows up leaves the developer with a
        # worse page than no presenter at all.
        def safely(fallback)
          yield
        rescue Exception # rubocop:disable Lint/RescueException
          fallback
        end
      end

      register "Hanami::Router::NotFoundError", NotFound
    end
  end
end
