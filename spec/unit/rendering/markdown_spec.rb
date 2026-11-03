# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::Rendering::Markdown do
  include ErrorPageDoubles

  def markdown_for(page)
    described_class.new(page).to_s
  end

  let(:app_frame) {
    frame(
      display_path: "app/actions/books/show.rb",
      lineno: 16,
      label: "Show#handle",
      source: excerpt(
        ["  def handle(request, response)", "    book_repo = deps[:book_repo]", "    result = book_repo.find_with_reviews(...)"],
        first_lineno: 14,
        highlight_lineno: 16
      )
    )
  }

  let(:gem_frame) {
    frame(kind: :gem, display_path: "rack-3.1.8/lib/rack/method_override.rb", lineno: 24, label: "Rack::MethodOverride#call")
  }

  it "renders the error as Markdown" do
    page = error_page(detailed_extras: ["Did you mean?  title"], frames: [app_frame, gem_frame])

    expect(markdown_for(page)).to eq(<<~TEXT)
      ## NoMethodError

      ```
      undefined method 'titel' for an instance of Book
      Did you mean?  title
      ```

      - Request: GET /books/247
      - Status: 500

      ### Backtrace (1 application frame of 2)
          app/actions/books/show.rb:16:in 'Show#handle'
        # rack-3.1.8/lib/rack/method_override.rb:24:in 'Rack::MethodOverride#call'

      ### Source: app/actions/books/show.rb:16
      ```ruby
        14 |   def handle(request, response)
        15 |     book_repo = deps[:book_repo]
      > 16 |     result = book_repo.find_with_reviews(...)
      ```
    TEXT
  end

  it "fences the message with more backticks than it holds, so it shows as written" do
    markdown = markdown_for(error_page(message: "Expected:\n```ruby\n- a\n```"))

    expect(markdown).to include("````\nExpected:\n```ruby\n- a\n```\n````")
  end

  it "fences the extras when there's no message" do
    expect(markdown_for(error_page(message: "", detailed_extras: ["  foo", "  ^^^"]))).to include("```\n  foo\n  ^^^\n```")
  end

  it "lists the cause chain" do
    expect(markdown_for(error_page(causes: ["TypeError", "ArgumentError"])))
      .to include("- Caused by: TypeError → ArgumentError")
  end

  it "omits the source section when no source is available" do
    expect(markdown_for(error_page(frames: [frame(source: nil)]))).not_to include("### Source")
  end

  it "omits the backtrace section when there are no frames" do
    markdown = markdown_for(error_page(frames: []))

    expect(markdown).not_to include("### Backtrace")
    expect(markdown).to include("- Status: 500")
  end

  it "truncates long backtraces" do
    markdown = markdown_for(error_page(frames: Array.new(30) { gem_frame }))

    expect(markdown).to include("### Backtrace (0 application frames of 30)")
    expect(markdown).to include("  # … 5 more frames")
  end

  it "leaves out the request when it can't be read" do
    page = error_page
    allow(page).to receive(:request).and_raise(NoMethodError)

    expect(markdown_for(page)).not_to include("- Request:")
  end

  it "never raises, and falls back to the class name, when the page can't be read" do
    page = error_page
    allow(page).to receive(:frames).and_raise(NoMethodError)

    expect(markdown_for(page)).to eq("## NoMethodError\n")
  end

  describe "with a diagnostic" do
    def page_with_diagnostic(**parts)
      error_page(exception_class: "RuntimeError", message: "boom", frames: [], diagnostic: diagnostic(**parts))
    end

    it "adds the explanation after the message, and the fix and dataset after the metadata" do
      page = page_with_diagnostic(
        title: "A short name",
        explanation: "Why it happened.",
        fix: {name: "Add a route", text: "Add it:\n\n```ruby\nget \"/x\"\n```"},
        dataset: {title: "Routes", columns: ["Method", "Path"], rows: [["GET", "/a|b"]]}
      )

      expect(markdown_for(page)).to eq(<<~TEXT)
        ## A short name (RuntimeError)

        ```
        boom
        ```

        Why it happened.

        - Request: GET /books/247
        - Status: 500

        ### Fix: Add a route

        Add it:

        ```ruby
        get "/x"
        ```

        ### Routes

        | Method | Path |
        | --- | --- |
        | GET | /a\\|b |
      TEXT
    end

    it "heads an unnamed fix generically, and lists a dataset without column headings" do
      page = page_with_diagnostic(fix: "Do this.", dataset: {title: "Pending", rows: {"a.rb" => "1"}})

      expect(markdown_for(page)).to include("### Fix it\n\nDo this.\n\n### Pending\n\n- a.rb — 1\n")
    end

    it "limits a long dataset, counting the rows it leaves out" do
      page = page_with_diagnostic(dataset: {title: "Routes", columns: ["Path"], rows: Array.new(52) { |index| "/#{index}" }})
      markdown = markdown_for(page)

      expect(markdown).to include("| /49 |\n\n… 2 more rows\n")
      expect(markdown).not_to include("| /50 |")
    end
  end
end
