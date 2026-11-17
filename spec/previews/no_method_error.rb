# frozen_string_literal: true

# The design's main case: a typo, with a did-you-mean and an error_highlight caret.
module Bookshelf
  module Structs
    class Book
      attr_reader :title

      def initialize(title:) = @title = title
      def update(title:) = @title = title
    end
  end

  module Actions
    module Books
      class Create
        def handle(params)
          book = Structs::Book.new(title: "Untitled")
          title = params[:title]
          book.updte(title: title)
        end
      end
    end
  end
end

Previews.scenario "no_method_error", "NoMethodError with a did-you-mean suggestion",
  method: "POST", path: "/books/247", session: {"_csrf_token" => "6c0f1b8a2e"} do
  Bookshelf::Actions::Books::Create.new.handle({title: "Dune"})
end
