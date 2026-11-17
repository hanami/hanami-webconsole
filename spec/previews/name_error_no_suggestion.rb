# frozen_string_literal: true

# A NameError with nothing close enough to suggest, so there's no suggestion callout.
module Bookshelf
  module Views
    module Books
      class Show
        def render
          xyzzy_unknown_helper
        end
      end
    end
  end
end

Previews.scenario "name_error_no_suggestion", "NameError with no suggestion" do
  Bookshelf::Views::Books::Show.new.render
end
