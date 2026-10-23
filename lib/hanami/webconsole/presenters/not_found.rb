# frozen_string_literal: true

require "did_you_mean/levenshtein"

module Hanami
  module Webconsole
    module Presenters
      # Presenter for `Hanami::Router::NotFoundError`.
      #
      # In development, a 404 usually means a typo, or a route that hasn't been added yet. To help
      # with both, we list the app's routes in a panel, offer the closest matches as "Did you mean"
      # suggestions, and highlight the rows for those matches in the list.
      #
      # The routes come from the slice attached to the error, via its router's `#routes`.
      #
      # @api private
      class NotFound < Base
        # HTTP methods that have their own method in the router DSL, for use in {#snippet}.
        #
        # HEAD maps to `get`, since the router defines a HEAD route alongside every GET route.
        SNIPPET_VERBS = {
          "GET" => "get", "HEAD" => "get", "POST" => "post", "PATCH" => "patch",
          "PUT" => "put", "DELETE" => "delete", "OPTIONS" => "options", "TRACE" => "trace"
        }.freeze

        def headline
          return "No route matched this request" if request_summary.empty?

          "No route matched #{request_summary}"
        end

        def lede
          return unless routes

          return "This app has no routes yet. Add one in config/routes.rb." if routes.empty?

          "Check the routes below for the one you meant, or add a new route."
        end

        # Returns the routes the developer probably meant, to show as chips under the message.
        #
        # @return [Array<String>]
        def suggestions
          @suggestions ||= near_paths.first(3)
        end

        # A route definition to paste, when there is nothing close enough to suggest.
        #
        # @return [String, nil]
        def snippet
          return unless snippet?

          # The snippet is Ruby code to paste into the routes file, so use `#inspect` to turn the
          # path into a string literal. This escapes any characters that are special inside double
          # quotes (`"`, `\` or `#{`), so the pasted route matches the requested path exactly.
          %(#{SNIPPET_VERBS.fetch(verb)} #{request_path.inspect}, to: "...")
        end

        # Slice routes are evaluated into the app's router, and a route doesn't record the slice
        # that defined it, so we can't tell whether the path belongs to a slice. Mention slices in
        # the note, rather than (possibly wrongly) pointing only to the app's routes file.
        #
        # @return [String, nil]
        def note
          return unless snippet?

          "Add it to `config/routes.rb`, or to a slice's routes (without its `at:` prefix)."
        end

        # List every route, no matter how many. The panel's filter box only searches the rows on
        # the page, so a truncated list would hide routes from the filter.
        #
        # @return [Array<Array>]
        def context_panels
          return [] if listed_routes.empty?

          [["Routes (#{listed_routes.length})", listed_routes.map { |route| row_for(route) }]]
        end

        private

        # Returns the routes of the slice that raised the error.
        #
        # Returns nil if there are no routes to read, i.e. with an older Hanami (whose error
        # carries no slice) or an older hanami-router (whose router can't list its routes). This
        # is different from an empty array, which means the app genuinely has no routes.
        #
        # @return [Array<Hanami::Router::Route>, nil]
        def routes
          router = exception.slice&.router if exception.respond_to?(:slice)
          Array(router.routes) if router.respond_to?(:routes)
        end

        # Hide HEAD routes. The router generates one for every GET, so showing them would double
        # up the list with routes the user never defined. `hanami routes` hides them for the same
        # reason.
        def listed_routes
          @listed_routes ||= Array(routes).reject(&:head?)
        end

        # Highlight the rows for suggested paths. Paths that exist only under a different HTTP
        # method don't need highlighting: the router raises `NotAllowedError` for those, so they
        # never reach here.
        def row_for(route)
          highlight = near_paths.include?(route.path)
          ["#{route.http_method} #{route.path}".strip, endpoint_for(route), false, highlight]
        end

        # Match the columns from `hanami routes`: the endpoint, followed by the route name and
        # constraints, if present.
        def endpoint_for(route)
          parts = [route.inspect_to.to_s]
          parts << "as #{route.inspect_as}" if route.as?
          parts << "(#{route.inspect_constraints})" if route.constraints?
          parts.join(" ")
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
          @near_paths ||= Array(routes)
            # Include only paths reachable by the same HTTP method
            .select { |route| route.http_method == verb || route.http_method == "*" }
            # A route path is a _pattern_, like `/books/:id`
            .map(&:path)
            .uniq
            .filter_map { |pattern| near_match(pattern) }
            .sort_by.with_index { |(_pattern, distance), index| [distance, index] }
            .map(&:first)
        end

        # @return [Array(String, Integer), nil] the pattern and its distance, when it is close
        def near_match(pattern)
          return if request_path.empty? || pattern == "/"

          projected = project(request_path, pattern)
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
        def project(request_path, pattern)
          segments = request_path.split("/", -1)
          pattern_segments = pattern.split("/", -1)

          if (glob = pattern_segments.index { |segment| segment.start_with?("*") })
            return request_path if segments.length <= glob

            segments = segments.first(glob) + [pattern_segments[glob]]
            pattern_segments = pattern_segments.first(glob + 1)
          end

          return request_path unless segments.length == pattern_segments.length

          segments.zip(pattern_segments).map { |segment, pattern_segment|
            pattern_segment.start_with?(":") ? pattern_segment : segment
          }.join("/")
        end

        def snippet?
          !request_path.empty? && SNIPPET_VERBS.key?(verb) && suggestions.empty?
        end

        def request_summary
          @request_summary ||= "#{verb} #{request_path}".strip
        end

        def verb
          @verb ||= env_value("REQUEST_METHOD")
        end

        def request_path
          @request_path ||= env_value("PATH_INFO")
        end

        def env_value(key)
          return "" unless exception.respond_to?(:env)

          exception.env.to_h[key].to_s
        end
      end

      register "Hanami::Router::NotFoundError", NotFound
    end
  end
end
