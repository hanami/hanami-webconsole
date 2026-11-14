# frozen_string_literal: true

# A long class name and a long, multi-line message.
module Bookshelf
  module Persistence
    module Relations
      module Books
        class InvalidAssociationConfigurationError < StandardError; end
      end
    end
  end
end

Previews.scenario "long_message", "Long class name and a multi-line message" do
  raise Bookshelf::Persistence::Relations::Books::InvalidAssociationConfigurationError, <<~MESSAGE
    Association :authors on relation :books could not be configured because the join relation :books_authors defines no foreign key pointing to :authors and none could be inferred from the schema.

    Check that books_authors.author_id exists and references authors.id, or pass `foreign_key:` explicitly when declaring the association.
  MESSAGE
end
