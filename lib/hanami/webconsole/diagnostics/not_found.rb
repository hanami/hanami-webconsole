# frozen_string_literal: true

require "did_you_mean/levenshtein"

module Hanami
  module Webconsole
    module Diagnostics
      # Diagnostic for `Hanami::Router::NotFoundError`.
      #
      # In development, a 404 usually means a typo, or a route that hasn't been added yet. To help
      # with both, the fix suggests the closest matching route (if there is one), and shows how to
      # add a new route. The dataset lists all the app's routes.
      #
      # @api private
      class NotFound
        # The HTTP methods that have their own method in the router DSL, mapped to those methods.
        # These are used to write the snippet for adding a new route.
        #
        # HEAD maps to `get`, since the router defines a HEAD route alongside every GET route.
        SNIPPET_VERBS = {
          "GET" => "get", "HEAD" => "get", "POST" => "post", "PATCH" => "patch",
          "PUT" => "put", "DELETE" => "delete", "OPTIONS" => "options", "TRACE" => "trace"
        }.freeze

        # Returns the exception.
        #
        # @return [Hanami::Router::NotFoundError]
        attr_reader :exception

        # @param exception [Hanami::Router::NotFoundError]
        # @param _context [Context] not used, since the routes come from the slice on the exception
        def initialize(exception, _context)
          @exception = exception
        end

        # Returns the title.
        #
        # This only names the situation. The router's message, shown below the title, gives the
        # request's method and path.
        def title = "No matching route"

        # Returns the fix.
        #
        # This suggests the closest matching route (if there is one), followed by how to add a new
        # route.
        #
        # The fix is only given a name when adding a new route is the one clear thing to do. When
        # there's also a suggestion, the fix offers two options, so we leave it unnamed, and the
        # page gives it a generic name instead.
        def fix
          text = [suggested_route_fix, new_route_fix].compact.join("\n\n")
          return if text.empty?

          {name: ("Add a route" unless suggested_route?), text:}
        end

        # Returns a sentence suggesting the closest matching route, for the fix.
        #
        # If the closest route has a distance of zero, then the requested path has the route's
        # shape, but failed one of its constraints (see {#nearest_match}). In this case, the
        # sentence says which constraints the route has.
        #
        # @return [String, nil] nil if no route is close enough to suggest
        private def suggested_route_fix
          pattern, distance = nearest_match
          return unless pattern

          if distance.zero?
            constrained_route = reachable_routes.find { _1.path == pattern && _1.constraints? }
          end
          return "Did you mean `#{pattern}`?" unless constrained_route

          "`#{constrained_route.http_method} #{pattern}` matches this path, but not its constraints " \
            "(`#{constrained_route.inspect_constraints}`)."
        end

        # Returns true if there is a route close enough to suggest.
        #
        # @return [Boolean]
        private def suggested_route?
          !nearest_match.nil?
        end

        # Returns a paragraph explaining how to add a new route for the request, for the fix. This
        # includes a snippet of the route definition to paste into the routes file.
        #
        # When the fix also suggests an existing route, this paragraph is worded as the alternative.
        #
        # Slice routes are loaded into the app's router, and a route doesn't record the slice that
        # defined it, so we can't tell whether the requested path belongs to a slice. Instead of
        # (possibly wrongly) pointing only to the app's routes file, we mention slices too.
        #
        # The snippet is Ruby code, so we use `#inspect` to turn the path into a string literal.
        # This escapes any characters that are special inside double quotes (`"`, `\` or `#{`), so
        # the pasted route matches the requested path exactly.
        #
        # @return [String, nil] nil if the request's HTTP method has no method of its own in the
        #   router DSL
        private def new_route_fix
          return unless SNIPPET_VERBS.key?(verb)

          <<~TEXT.chomp
            #{suggested_route? ? "Otherwise, add" : "Add"} a route to `config/routes.rb`, or to a slice's routes (without its `at:` prefix):

            ```ruby
            #{SNIPPET_VERBS.fetch(verb)} #{request_path.inspect}, to: "..."
            ```
          TEXT
        end

        # Returns the app's routes as a dataset, with the same columns as `hanami routes`.
        #
        # This lists every route, no matter how many there are. The panel's filter box only searches
        # the rows on the page, so if we truncated the list, some routes would be hidden from the
        # filter.
        #
        # @return [Hash{Symbol => Object}, nil] the dataset, as `{title:, columns:, rows:}`, or nil
        #   if there are no routes
        def dataset
          return if listable_routes.empty?

          {
            title: "Routes",
            columns: ["Method", "Path", "Endpoint"],
            rows: listable_routes.map { |route| [route.http_method, route.path, endpoint_for(route)] }
          }
        end

        private

        # Returns the routes to list in the dataset.
        #
        # This leaves out HEAD routes. The router generates one for every GET route, so showing them
        # would double up the list with routes the user never defined. `hanami routes` hides them
        # for the same reason.
        #
        # @return [Array<Hanami::Router::Route>]
        def listable_routes
          @listable_routes ||= routes.reject(&:head?)
        end

        # Returns the routes that the request could have matched, which are the routes for its HTTP
        # method, or for any method.
        #
        # We don't need to consider paths that only exist under a different method, because the
        # router raises a `NotAllowedError` for those, and they never reach here.
        #
        # @return [Array<Hanami::Router::Route>]
        def reachable_routes
          routes.select { |route| route.http_method == verb || route.http_method == "*" }
        end

        # Returns the routes of the slice that raised the error.
        #
        # @return [Array<Hanami::Router::Route>]
        def routes
          @routes ||= exception.slice.router.routes
        end

        # Returns the text for a route's endpoint column, matching how `hanami routes` shows it.
        #
        # This is the route's endpoint, followed by its name and constraints, if it has them.
        #
        # @example
        #   endpoint_for(route) # => "books.show as :book (id: /\d+/)"
        #
        # @param route [Hanami::Router::Route]
        #
        # @return [String]
        def endpoint_for(route)
          parts = [route.inspect_to.to_s]
          parts << "as #{route.inspect_as}" if route.as?
          parts << "(#{route.inspect_constraints})" if route.constraints?
          parts.join(" ")
        end

        # Returns the route pattern closest to the requested path, with its distance, or nil if no
        # pattern is close. When patterns tie, the route defined first wins.
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
        #
        # @return [Array(String, Integer), nil]
        def nearest_match
          return @nearest_match if defined?(@nearest_match)

          @nearest_match = reachable_routes
            # A route path is a _pattern_, like `/books/:id`
            .map(&:path)
            .uniq
            .filter_map { |pattern| near_match(pattern) }
            .each_with_index
            .min_by { |(_pattern, distance), index| [distance, index] }
            &.first
        end

        # Returns the given route pattern along with its distance from the requested path, if the
        # pattern is close enough to suggest (see {#nearest_match}).
        #
        # @param pattern [String] a route path, e.g. `"/books/:id"`
        #
        # @return [Array(String, Integer), nil] the pattern and its distance, or nil if it isn't
        #   close
        def near_match(pattern)
          return if pattern == "/"

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
        #
        # @param request_path [String]
        # @param pattern [String]
        #
        # @return [String]
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

        # Returns the request's HTTP method.
        #
        # @return [String] e.g. `"GET"`
        def verb
          exception.env["REQUEST_METHOD"]
        end

        # Returns the requested path, which didn't match any route.
        #
        # @return [String]
        def request_path
          exception.env["PATH_INFO"]
        end
      end

      register "Hanami::Router::NotFoundError", NotFound
    end
  end
end
