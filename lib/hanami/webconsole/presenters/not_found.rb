# frozen_string_literal: true

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

        # Ruby's own spell checker, over the paths this app answers for the requested method. It
        # is what powers `did_you_mean`, so a route typo is scored the same way a method typo is,
        # and there is no bespoke distance heuristic here to get wrong.
        def near_paths
          @near_paths ||= safely([]) {
            next [] if path.empty? || candidate_paths.empty?
            next [] unless defined?(::DidYouMean::SpellChecker)

            ::DidYouMean::SpellChecker.new(dictionary: candidate_paths).correct(path)
          }
        end

        # Only paths reachable by the method that was requested: suggesting a POST-only path for
        # a GET would send the developer somewhere that raises again.
        def candidate_paths
          @candidate_paths ||= safely([]) {
            routes
              .select { |route| route.http_method == verb || route.http_method == "*" }
              .map(&:path)
              .uniq
          }
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
