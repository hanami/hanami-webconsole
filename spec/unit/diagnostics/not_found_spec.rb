# frozen_string_literal: true

require "hanami/router"

RSpec.describe Hanami::Webconsole::Diagnostics::NotFound do
  subject(:diagnostic) { diagnostic_for(path: "/nope") }

  def diagnostic_for(**options)
    Hanami::Diagnostics::Wrapper.new(described_class.new(error(**options), nil))
  end

  def routes(&block)
    Hanami::Router.new(resolver: ->(_path, _to) { ->(_env) { [200, {}, []] } }, &block)
  end

  let(:router) {
    routes {
      get "/books", to: "books.index", as: :books
      post "/books", to: "books.create"
      get "/books/:id", to: "books.show", id: /\d+/
    }
  }

  # Builds a stand-in for `Hanami::Router::NotFoundError`
  def error(path:, method: "GET", router: self.router)
    slice = Struct.new(:router).new(router)

    Class.new(StandardError) {
      define_method(:env) { {"REQUEST_METHOD" => method, "PATH_INFO" => path} }
      define_method(:slice) { slice }
    }.new("No route found for #{method} #{path}")
  end

  it "sets a title and no explanation" do
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

    it "is nil when there are no routes" do
      expect(diagnostic_for(path: "/nope", router: routes {}).dataset).to be_nil
    end
  end

  describe "#fix" do
    def fix_text(**options)
      diagnostic_for(**options).fix&.text
    end

    describe "with a route that's close" do
      it "leaves the route to the suggestion, as a did_you_mean correction" do
        expect(diagnostic_for(path: "/boks").fix).to be_nil
      end

      it "says which constraint the path failed" do
        expect(fix_text(path: "/books/abc")).to start_with(
          "`GET /books/:id` matches this path, but not its constraints (`id: /\\d+/`)."
        )
      end
    end

    describe "with nothing close" do
      it "says where to add a route" do
        expect(diagnostic.fix).to have_attributes(
          name: "Add a route",
          text: "Add a route to `config/routes.rb`, or to a slice's routes."
        )
      end

      it "says where to add a route for a HEAD request, since the router adds HEAD itself" do
        expect(diagnostic_for(path: "/nope", method: "HEAD").fix.name).to eq("Add a route")
      end

      it "is nil for a method with no router DSL of its own" do
        expect(diagnostic_for(path: "/nope", method: "PROPFIND").fix).to be_nil
      end

      it "offers the route to add when there are no routes yet" do
        expect(diagnostic_for(path: "/nope", router: routes {}).fix.name).to eq("Add a route")
      end
    end

    describe "suggestions" do
      def suggestion(**options)
        Hanami::Webconsole::Diagnostics::NotFound.new(error(**options), nil).corrections.first
      end

      it "suggests the closest path for a typo" do
        expect(suggestion(path: "/boks")).to eq("/books")
      end

      it "reads a dynamic segment as the param it would fill" do
        expect(suggestion(path: "/bookz/1")).to eq("/books/:id")
      end

      it "reads a glob as the rest of the path" do
        files = routes { get "/files/*path", to: "files.show" }

        expect(suggestion(path: "/filez/a/b.txt", router: files)).to eq("/files/*path")
      end

      it "finds routes in a scope" do
        scoped = routes { scope("admin") { get "/users", to: "admin.users.index" } }

        expect(suggestion(path: "/admin/user", router: scoped)).to eq("/admin/users")
      end

      it "suggests nothing when a route matches but for its constraints, since the fix explains that" do
        expect(suggestion(path: "/books/abc")).to be_nil
      end

      it "never suggests the root path for a short path" do
        rooted = routes {
          root to: "home.show"
          get "/books", to: "books.index"
        }

        expect(suggestion(path: "/x", router: rooted)).to be_nil
      end

      it "doesn't suggest a route of another shape that is only close as text" do
        expect(suggestion(path: "/bookz/1")).not_to eq("/books")
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
        # `/boo` is two changes away from `/bookz`, while `/books` is just one.
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
  end

  it "is registered for the router's not found error" do
    expect(Hanami::Diagnostics::Registry.entries).to include(
      "Hanami::Router::NotFoundError" => [described_class.name]
    )
  end

  describe "as a did_you_mean spell checker" do
    it "gives the exception its corrections, as Ruby does for a NameError" do
      router = self.router
      klass = stub_const("SpecRouterNotFoundError", Class.new(StandardError) {
        define_method(:env) { {"REQUEST_METHOD" => "GET", "PATH_INFO" => "/boks"} }
        define_method(:slice) { Struct.new(:router).new(router) }
      })
      exception = klass.new("No route found for GET /boks")

      described_class.new(exception, nil)

      expect(exception.corrections).to eq(["/books"])
      expect(exception.detailed_message(highlight: false)).to include("Did you mean?  /books")
    end
  end
end
