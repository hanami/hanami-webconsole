# frozen_string_literal: true

# An actionable error whose fix has to be confirmed before it runs.
module Bookshelf
  class PendingMigrationError < StandardError; end

  module Previews
    class PendingMigration
      def initialize(_exception, _context); end

      def title = "Migrations are pending"
      def explanation = "The database is behind the app. Two migrations haven't run yet."

      def fix
        {
          name: "Reset the database",
          text: "Drop the database, then run every migration from scratch.",
          destructive: true
        }
      end

      def run_fix = "Done"
    end
  end
end

unless Hanami::Diagnostics::Registry.entries.any? { |entry| entry.first == "Bookshelf::PendingMigrationError" }
  Hanami::Diagnostics::Registry.register "Bookshelf::PendingMigrationError", Bookshelf::Previews::PendingMigration
end

Previews.scenario "destructive_fix", "Actionable error with a destructive fix" do
  raise Bookshelf::PendingMigrationError, "2 migrations are pending: 20261101_create_books, 20261102_add_isbn"
end
