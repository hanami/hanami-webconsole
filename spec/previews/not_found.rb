# frozen_string_literal: true

require "hanami/router"

# A 404 handled by the NotFound diagnostic, with a close route to suggest.
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
