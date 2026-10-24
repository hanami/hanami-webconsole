# frozen_string_literal: true

require "hanami/webconsole/presenters/not_found"

RSpec.describe Hanami::Webconsole::Presenters::NotFound do
  subject(:presenter) { described_class.new(exception) }

  let(:exception) { error(routes: routes) }

  let(:routes) {
    [
      route("GET", "/books", "books.index", as: :books),
      route("HEAD", "/books", "books.index", as: :books),
      route("POST", "/books", "books.create"),
      route("GET", "/books/:id", "books.show", constraints: {id: /\d+/})
    ]
  }

  # Stands in for `Hanami::Router::Route`, which this gem does not depend on.
  def route(http_method, path, to, as: nil, constraints: {})
    Class.new do
      define_method(:http_method) { http_method }
      define_method(:path) { path }
      define_method(:to) { to }
      define_method(:as) { as }
      define_method(:constraints) { constraints }
      define_method(:head?) { http_method == "HEAD" }
      define_method(:as?) { !as.nil? }
      define_method(:constraints?) { constraints.any? }
      define_method(:inspect_to) { to.to_s }
      define_method(:inspect_as) { as.inspect }
      define_method(:inspect_constraints) { constraints.map { |k, v| "#{k}: #{v.inspect}" }.join(", ") }
    end.new
  end

  # Stands in for `Hanami::Router::NotFoundError`, which carries the slice that was routing.
  def error(path: "/nope", method: "GET", routes: [])
    router = Class.new { define_method(:routes) { routes } }.new
    slice = Class.new { define_method(:router) { router } }.new

    Class.new(StandardError) {
      define_method(:env) { {"REQUEST_METHOD" => method, "PATH_INFO" => path} }
      define_method(:slice) { slice }
    }.new("No route found for #{method} #{path}")
  end

  describe "#headline" do
    it "names the request that went unmatched" do
      expect(presenter.headline).to eq("No route matched GET /nope")
    end
  end

  describe "#lede" do
    it "points to the routes listed below" do
      expect(presenter.lede).to eq("Check the routes below for the one you meant, or add a new route.")
    end

    it "says so when the app has no routes" do
      expect(described_class.new(error(routes: [])).lede).to eq(
        "This app has no routes yet. Add one in config/routes.rb."
      )
    end
  end

  describe "#context_panels" do
    subject(:panel) { presenter.context_panels.first }

    it "lists the routes, titled with their count" do
      expect(panel.first).to eq("Routes (3)")
    end

    it "lists each route as its method and path" do
      expect(panel.last.map(&:first)).to eq(["GET /books", "POST /books", "GET /books/:id"])
    end

    it "shows the endpoint, name and constraints, as `hanami routes` does" do
      expect(panel.last.map { |row| row[1] }).to eq(
        ["books.index as :books", "books.create", "books.show (id: /\\d+/)"]
      )
    end

    it "hides the HEAD routes the router generates for every GET" do
      expect(panel.last.map(&:first)).not_to include("HEAD /books")
    end

    it "lists every route of a large app, so the filter can find any of them" do
      many = Array.new(1_000) { |i| route("GET", "/route-#{i}", "route.#{i}") }

      panel = described_class.new(error(routes: many)).context_panels.first

      expect(panel.first).to eq("Routes (1000)")
      expect(panel.last.length).to eq(1_000)
    end
  end

  describe "#suggestions" do
    it "suggests the closest path for a typo" do
      presenter = described_class.new(error(path: "/boks", routes: routes))

      expect(presenter.suggestions).to eq(["/books"])
    end

    it "reads a dynamic segment as the param it would fill" do
      presenter = described_class.new(error(path: "/bookz/1", routes: routes))

      expect(presenter.suggestions).to eq(["/books/:id"])
    end

    it "suggests the route whose constraints the path failed" do
      presenter = described_class.new(error(path: "/books/abc", routes: routes))

      expect(presenter.suggestions).to eq(["/books/:id"])
    end

    it "reads a glob as the rest of the path" do
      files = routes + [route("GET", "/files/*path", "files.show")]
      presenter = described_class.new(error(path: "/filez/a/b.txt", routes: files))

      expect(presenter.suggestions).to eq(["/files/*path"])
    end

    it "never suggests the root path for a short path" do
      rooted = routes + [route("GET", "/", "home.show")]
      presenter = described_class.new(error(path: "/x", routes: rooted))

      expect(presenter.suggestions).to eq([])
    end

    it "does not suggest a route of another shape that is only close as text" do
      presenter = described_class.new(error(path: "/bookz/1", routes: routes))

      expect(presenter.suggestions).not_to include("/books")
    end

    it "is not misled by a long param value shared with other routes" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      others = routes + [route("GET", "/users/:id", "users.show"), route("GET", "/orders/:id", "orders.show")]

      expect(described_class.new(error(path: "/bookz/#{uuid}", routes: others)).suggestions).to eq(["/books/:id"])
      expect(described_class.new(error(path: "/xyz/#{uuid}", routes: others)).suggestions).to eq([])
    end

    it "does not let param or glob names make an unrelated pattern look close" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      files = routes + [route("GET", "/files/*path", "files.show")]

      expect(described_class.new(error(path: "/orders/#{uuid}", routes: files)).suggestions).to eq([])
    end

    it "only suggests paths reachable by the method that was requested" do
      presenter = described_class.new(error(path: "/bookss", method: "DELETE", routes: routes))

      expect(presenter.suggestions).to eq([])
    end

    it "suggests nothing when nothing is close" do
      expect(presenter.suggestions).to eq([])
    end
  end

  describe "highlighted rows" do
    it "highlights every route for a suggested path, whatever its method" do
      presenter = described_class.new(error(path: "/boks", routes: routes))
      rows = presenter.context_panels.first.last

      expect(rows.select(&:last).map(&:first)).to eq(["GET /books", "POST /books"])
    end

    it "highlights nothing when nothing is close" do
      expect(presenter.context_panels.first.last.select(&:last)).to eq([])
    end
  end

  describe "#snippet" do
    it "offers the route definition that is missing" do
      expect(presenter.snippet).to eq(%(get "/nope", to: "..."))
    end

    it "uses the DSL method for the request's own verb" do
      presenter = described_class.new(error(path: "/nope", method: "DELETE", routes: routes))

      expect(presenter.snippet).to eq(%(delete "/nope", to: "..."))
    end

    it "defines a GET for a HEAD request, since the router adds HEAD itself" do
      presenter = described_class.new(error(path: "/nope", method: "HEAD", routes: routes))

      expect(presenter.snippet).to eq(%(get "/nope", to: "..."))
    end

    it "is nil when there is a closer route to suggest instead" do
      presenter = described_class.new(error(path: "/boks", routes: routes))

      expect(presenter.snippet).to be_nil
    end

    it "is nil for a method with no router DSL of its own" do
      presenter = described_class.new(error(path: "/nope", method: "PROPFIND", routes: routes))

      expect(presenter.snippet).to be_nil
    end

    it "quotes the path as a Ruby string, whatever it contains" do
      presenter = described_class.new(error(path: %(/a"b/\#{c}), routes: routes))

      expect(presenter.snippet).to eq(%(get "/a\\"b/\\\#{c}", to: "..."))
    end

    it "carries a note pointing at the app and slice routes" do
      expect(presenter.note).to eq("Add it to `config/routes.rb`, or to a slice's routes (without its `at:` prefix).")
    end
  end

  describe "when the error misbehaves, as the error page reads it" do
    subject(:presenter) { Hanami::Webconsole::Presenters::Guard.new(described_class.new(exception)) }

    let(:exception) {
      Class.new(StandardError) {
        def env = raise("no env")

        def slice = raise("no slice")
      }.new("boom")
    }

    it "still renders, with nothing to show" do
      expect(presenter.headline).to be_nil
      expect(presenter.lede).to be_nil
      expect(presenter.suggestions).to eq([])
      expect(presenter.snippet).to be_nil
      expect(presenter.context_panels).to eq([])
    end
  end

  describe "when the router fails to list its routes, as the error page reads it" do
    subject(:presenter) { Hanami::Webconsole::Presenters::Guard.new(described_class.new(exception)) }

    let(:exception) {
      router = Class.new { def routes = raise("no routes") }.new
      slice = Class.new { define_method(:router) { router } }.new

      Class.new(StandardError) {
        define_method(:env) { {"REQUEST_METHOD" => "GET", "PATH_INFO" => "/nope"} }
        define_method(:slice) { slice }
      }.new("No route found for GET /nope")
    }

    it "does not claim the app has no routes" do
      expect(presenter.lede).to be_nil
    end

    it "keeps the parts that do not need the routes" do
      expect(presenter.headline).to eq("No route matched GET /nope")
      expect(presenter.context_panels).to eq([])
    end
  end

  describe "registration" do
    it "is registered for the router's not found error" do
      expect(Hanami::Webconsole::Presenters.registered).to include(
        "Hanami::Router::NotFoundError" => described_class
      )
    end
  end
end
