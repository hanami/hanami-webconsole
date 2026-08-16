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
  def error(path: "/nope", method: "GET", routes: [], slice: :build)
    router = Class.new { define_method(:routes) { routes } }.new
    slice = Class.new { define_method(:router) { router } }.new if slice == :build

    Class.new(StandardError) {
      define_method(:env) { {"REQUEST_METHOD" => method, "PATH_INFO" => path} }
      define_method(:slice) { slice }
    }.new("No route found for #{method} #{path}")
  end

  describe "#headline" do
    it "names the request that went unmatched" do
      expect(presenter.headline).to eq("No route matched GET /nope")
    end

    it "falls back when the error carries no request" do
      exception = Class.new(StandardError).new("boom")

      expect(described_class.new(exception).headline).to eq("No route matched this request")
    end
  end

  describe "#lede" do
    it "counts the routes that were available, as the panel lists them" do
      expect(presenter.lede).to eq("The router has 3 routes, and none of them matched this request.")
    end

    it "counts one route in the singular" do
      one = [route("GET", "/books", "books.index"), route("HEAD", "/books", "books.index")]

      expect(described_class.new(error(routes: one)).lede).to eq(
        "The router has 1 route, and it did not match this request."
      )
    end

    it "says so when the app has no routes" do
      expect(described_class.new(error(routes: [])).lede).to eq(
        "This app has no routes yet. Add one in config/routes.rb."
      )
    end

    it "is nil when the routes cannot be read, leaving the error's own message to speak" do
      expect(described_class.new(error(slice: nil)).lede).to be_nil
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

    it "keeps HEAD routes when the request itself was a HEAD" do
      panel = described_class.new(error(method: "HEAD", routes: routes)).context_panels.first

      expect(panel.last.map(&:first)).to include("HEAD /books")
    end

    it "truncates a very long list, and says that it did" do
      many = Array.new(described_class::MAX_ROUTES + 5) { |i| route("GET", "/route-#{i}", "route.#{i}") }

      panel = described_class.new(error(routes: many)).context_panels.first

      expect(panel.first).to eq("Routes (#{described_class::MAX_ROUTES} of #{many.length})")
      expect(panel.last.length).to eq(described_class::MAX_ROUTES)
    end

    it "is empty when the routes cannot be read" do
      expect(described_class.new(error(slice: nil)).context_panels).to eq([])
    end
  end

  describe "#suggestions" do
    it "suggests the closest path for a typo" do
      presenter = described_class.new(error(path: "/boks", routes: routes))

      expect(presenter.suggestions).to eq(["/books"])
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

    it "highlights a path that exists only under another method" do
      presenter = described_class.new(error(path: "/books", method: "DELETE", routes: routes))
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

    it "carries a note pointing at the routes file" do
      expect(presenter.note).to eq("Add it to `config/routes.rb`.")
    end
  end

  describe "when the error misbehaves" do
    let(:exception) {
      Class.new(StandardError) {
        def env = raise("no env")

        def slice = raise("no slice")
      }.new("boom")
    }

    it "still renders, with nothing to show" do
      expect(presenter.headline).to eq("No route matched this request")
      expect(presenter.lede).to be_nil
      expect(presenter.suggestions).to eq([])
      expect(presenter.snippet).to be_nil
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
