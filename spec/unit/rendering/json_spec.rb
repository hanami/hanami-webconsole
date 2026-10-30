# frozen_string_literal: true

require "json"

RSpec.describe Hanami::Webconsole::Rendering::JSON do
  include ErrorPageDoubles

  def json_for(page)
    JSON.parse(described_class.new(page).to_s)
  end

  it "renders the error as JSON" do
    json = json_for(error_page(causes: ["ArgumentError"]))

    expect(json).to include(
      "error" => "NoMethodError",
      "status" => 500,
      "actionable" => false,
      "diagnostic" => nil,
      "causes" => ["ArgumentError"]
    )
    expect(json["backtrace"].first).to eq(
      "/app/lib/bookshelf/repositories/book_repo.rb:11:in 'Bookshelf::Repositories::BookRepo#find'"
    )
    expect(json["request"]).to include("method" => "GET", "path" => "/books/247")
  end

  it "includes the diagnostic, saying whether the fix can run, but not how" do
    page = error_page(
      diagnostic: diagnostic(
        title: "Title",
        fix: {name: "Generate action", text: "Generate it."},
        run_fix: "done",
        dataset: {title: "Actions", rows: ["books.index"]}
      )
    )
    json = json_for(page)

    expect(json["actionable"]).to be(true)
    expect(json["diagnostic"]).to eq(
      "title" => "Title",
      "explanation" => nil,
      "fix" => {"name" => "Generate action", "text" => "Generate it.", "runnable" => true, "destructive" => false},
      "dataset" => {"title" => "Actions", "columns" => [], "rows" => [["books.index"]]}
    )
  end
end
