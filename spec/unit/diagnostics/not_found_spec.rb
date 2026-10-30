# frozen_string_literal: true

require "hanami/router"

# Built against real routes from hanami-router, so a change to the router's API shows up here.
RSpec.describe Hanami::Webconsole::Diagnostics::NotFound do
  subject(:diagnostic) { read(path: "/nope") }

  # Real routes. String endpoints stay as they are, as in a Hanami app, where they name actions.
  let(:router) {
    Hanami::Router.new(resolver: ->(_path, _to) { ->(_env) { [200, {}, []] } }) do
      get "/books", to: "books.index", as: :books
      post "/books", to: "books.create"
      get "/books/:id", to: "books.show", id: /\d+/
    end
  }

  def routes(&block)
    Hanami::Router.new(resolver: ->(_path, _to) { ->(_env) { [200, {}, []] } }, &block)
  end

  # Stands in for `Hanami::Router::NotFoundError`, which is defined in hanami, and carries the
  # slice that was routing.
  def error(path:, method: "GET", router: self.router)
    slice = Struct.new(:router).new(router)

    Class.new(StandardError) {
      define_method(:env) { {"REQUEST_METHOD" => method, "PATH_INFO" => path} }
      define_method(:slice) { slice }
    }.new("No route found for #{method} #{path}")
  end

  def read(**options)
    Hanami::Webconsole::Diagnostics::Wrapper.new(described_class.new(error(**options), nil))
  end

  def fix_text(**options)
    read(**options).fix&.text
  end

  it "names the situation, without restating the router's message, and has no explanation" do
    expect(diagnostic.title).to eq("No matching route")
    expect(diagnostic.explanation).to be_nil
  end

  describe "#dataset" do
    subject(:dataset) { diagnostic.dataset }

    it "lists the routes in columns" do
      expect(dataset.title).to eq("Routes")
      expect(dataset.columns).to eq(["Method", "Path", "Endpoint"])
    end

    it "shows each route's endpoint, name and constraints, as `hanami routes` does" do
      expect(dataset.rows).to eq(
        [
          ["GET", "/books", "books.index as :books"],
          ["POST", "/books", "books.create"],
          ["GET", "/books/:id", "books.show (id: /\\d+/)"]
        ]
      )
    end

    it "hides the HEAD routes the router generates for every GET" do
      expect(dataset.rows.map(&:first)).not_to include("HEAD")
    end

    it "lists every route of a large app, so the filter can find any of them" do
      many = routes { 1_000.times { |i| get "/route-#{i}", to: "route.#{i}" } }

      expect(read(path: "/nope", router: many).dataset.rows.length).to eq(1_000)
    end

    it "is nil when there are no routes" do
      expect(read(path: "/nope", router: routes {}).dataset).to be_nil
    end
  end

  describe "#fix, with a route that's close" do
    it "suggests the closest path for a typo" do
      expect(fix_text(path: "/boks")).to start_with("Did you mean `/books`?")
    end

    it "reads a dynamic segment as the param it would fill" do
      expect(fix_text(path: "/bookz/1")).to start_with("Did you mean `/books/:id`?")
    end

    it "says which constraint the path failed" do
      expect(fix_text(path: "/books/abc")).to start_with(
        "`GET /books/:id` matches this path, but not its constraints (`id: /\\d+/`)."
      )
    end

    it "reads a glob as the rest of the path" do
      files = routes { get "/files/*path", to: "files.show" }

      expect(fix_text(path: "/filez/a/b.txt", router: files)).to start_with("Did you mean `/files/*path`?")
    end

    it "finds routes in a scope" do
      scoped = routes { scope("admin") { get "/users", to: "admin.users.index" } }

      expect(fix_text(path: "/admin/user", router: scoped)).to start_with("Did you mean `/admin/users`?")
    end

    it "still offers the route to add, in case a new one was meant" do
      expect(fix_text(path: "/boks")).to include(<<~TEXT.chomp)
        Otherwise, add a route to `config/routes.rb`, or to a slice's routes (without its `at:` prefix):

        ```ruby
        get "/boks", to: "..."
        ```
      TEXT
    end

    it "is unnamed, since it offers two actions" do
      expect(read(path: "/boks").fix.name).to be_nil
    end
  end

  describe "#fix, with nothing close" do
    it "offers the route to add" do
      expect(diagnostic.fix).to have_attributes(name: "Add a route", text: <<~TEXT.chomp)
        Add a route to `config/routes.rb`, or to a slice's routes (without its `at:` prefix):

        ```ruby
        get "/nope", to: "..."
        ```
      TEXT
    end

    it "uses the DSL method for the request's own verb" do
      expect(fix_text(path: "/nope", method: "DELETE")).to include(%(delete "/nope", to: "..."))
    end

    it "defines a GET for a HEAD request, since the router adds HEAD itself" do
      expect(fix_text(path: "/nope", method: "HEAD")).to include(%(get "/nope", to: "..."))
    end

    it "quotes the path as a Ruby string, whatever it contains" do
      expect(fix_text(path: %(/a"b/\#{c}))).to include(%(get "/a\\"b/\\\#{c}", to: "..."))
    end

    it "is nil for a method with no router DSL of its own" do
      expect(read(path: "/nope", method: "PROPFIND").fix).to be_nil
    end

    it "offers the route to add when there are no routes yet" do
      expect(read(path: "/nope", router: routes {}).fix.name).to eq("Add a route")
    end
  end

  describe "suggestions" do
    def suggestion(**options)
      fix_text(**options)[/\ADid you mean `([^`]+)`/, 1]
    end

    it "never suggests the root path for a short path" do
      rooted = routes {
        root to: "home.show"
        get "/books", to: "books.index"
      }

      expect(suggestion(path: "/x", router: rooted)).to be_nil
    end

    it "doesn't suggest a route of another shape that is only close as text" do
      expect(fix_text(path: "/bookz/1")).not_to include("`/books`")
    end

    it "is not misled by a long param value shared with other routes" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      others = routes {
        get "/books/:id", to: "books.show"
        get "/users/:id", to: "users.show"
        get "/orders/:id", to: "orders.show"
      }

      expect(suggestion(path: "/bookz/#{uuid}", router: others)).to eq("/books/:id")
      expect(suggestion(path: "/xyz/#{uuid}", router: others)).to be_nil
    end

    it "doesn't let param or glob names make an unrelated pattern look close" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      files = routes { get "/files/*path", to: "files.show" }

      expect(suggestion(path: "/orders/#{uuid}", router: files)).to be_nil
    end

    it "suggests the closest route, even when it is defined later" do
      # `/boo` is two changes away from `/bookz`, and `/books` is one.
      later = routes {
        get "/boo", to: "boo.index"
        get "/books", to: "books.index"
      }

      expect(suggestion(path: "/bookz", router: later)).to eq("/books")
    end

    it "suggests the route defined first when two are equally close" do
      tied = routes {
        get "/cars", to: "cars.index"
        get "/cats", to: "cats.index"
      }

      expect(suggestion(path: "/caws", router: tied)).to eq("/cars")
    end

    it "only suggests paths reachable by the method that was requested" do
      expect(suggestion(path: "/bookss", method: "DELETE")).to be_nil
    end
  end

  describe "when the error misbehaves" do
    subject(:diagnostic) {
      exception = Class.new(StandardError) {
        def env = raise("no env")

        def slice = raise("no slice")
      }.new("boom")

      Hanami::Webconsole::Diagnostics::Wrapper.new(described_class.new(exception, nil))
    }

    it "has nothing to show, and doesn't raise" do
      expect(diagnostic.fix).to be_nil
      expect(diagnostic.dataset).to be_nil
    end
  end

  describe "when the router fails to list its routes" do
    subject(:diagnostic) { read(path: "/nope", router: Class.new { def routes = raise("no routes") }.new) }

    it "has nothing to show, and doesn't raise" do
      expect(diagnostic.fix).to be_nil
      expect(diagnostic.dataset).to be_nil
    end
  end

  it "is registered for the router's not found error" do
    expect(Hanami::Webconsole::Diagnostics.registry).to include("Hanami::Router::NotFoundError" => described_class)
  end
end
