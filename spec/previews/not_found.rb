# frozen_string_literal: true

require "hanami/router"

# A 404 handled by the NotFound diagnostic, with a close route to suggest.

# The `hanami` gem defines this, not hanami-router, so stand one in when Hanami isn't loaded. The
# diagnostics registry matches on the class name, so the stand-in gets the real diagnostic.
unless defined?(Hanami::Router::NotFoundError)
  class Hanami::Router::NotFoundError < StandardError # rubocop:disable Style/ClassAndModuleChildren
    attr_reader :env

    def initialize(env)
      @env = env
      super("No route found for #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}")
    end
  end
end

module Previews
  ROUTER = Hanami::Router.new(resolver: ->(_path, _to) { ->(_env) { [200, {}, []] } }) {
    root to: "home.show"
    get "/books", to: "books.index", as: :books
    post "/books", to: "books.create"
    get "/books/:id", to: "books.show", id: /\d+/
    patch "/books/:id", to: "books.update"
    delete "/books/:id", to: "books.destroy"
  }
end

Previews.scenario "not_found", "No matching route, with a route to suggest", path: "/bookz" do
  slice = Struct.new(:router).new(Previews::ROUTER)
  env = {"REQUEST_METHOD" => "GET", "PATH_INFO" => "/bookz"}

  raise Hanami::Router::NotFoundError.new(env).tap { |error|
    error.define_singleton_method(:slice) { slice }
  }
end
