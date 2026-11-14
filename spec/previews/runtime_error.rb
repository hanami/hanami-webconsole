# frozen_string_literal: true

require "json"

# A plain crash from deep inside a gem, so most frames are gem frames.
module Bookshelf
  module Operations
    class ImportBooks
      def call(payload)
        JSON.parse(payload)
      end
    end
  end
end

Previews.scenario "runtime_error", "Crash inside a gem, with many gem frames" do
  Bookshelf::Operations::ImportBooks.new.call("{not json")
end
