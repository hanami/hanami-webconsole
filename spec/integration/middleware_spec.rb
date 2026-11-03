# frozen_string_literal: true

require "json"

# A full integration test, nothing stubbed, working through the full stack.
RSpec.describe Hanami::Webconsole::Middleware, type: :rack do
  let(:app) { described_class.new(inner_app, slice) }

  # Stands in for app code: a typo, in a method with a local in it.
  def find_book
    title = "Ruby"
    title.titel
  end

  let(:inner_app) {
    spec = self
    ->(_env) { spec.find_book }
  }

  # The app root is this directory, so the frames in this file are the app's frames.
  let(:config) { double("Config", render_error_responses: Hash.new(:internal_server_error), root: __dir__) }
  let(:slice) { double("Slice", config:, app: double("App", with_slices: [])) }

  def page_data
    JSON.parse(last_response.body[%r{<script type="application/json" data-webconsole-frames>(.*?)</script>}m, 1])
  end

  it "renders the error page for a real exception" do
    get "/books/247", {}, "HTTP_ACCEPT" => "text/html"

    expect(last_response.status).to eq(500)
    expect(last_response.headers["content-type"]).to eq("text/html; charset=utf-8")
    expect(last_response.body).to include(%(<h1 data-webconsole-headline>NoMethodError</h1>))
    # Ruby 3.4 quotes the method as 'titel', and older Rubies as `titel'.
    expect(last_response.body).to match(%r{undefined method <code>(&#39;|`)titel&#39;</code>})
    expect(page_data["frames"][page_data["initialFrame"]]).to include(
      "displayPath" => File.basename(__FILE__),
      "label" => a_string_including("find_book")
    )
  end

  it "renders the same error as text" do
    get "/books/247", {}, "HTTP_ACCEPT" => "text/plain"

    expect(last_response.status).to eq(500)
    # Ruby 3.4 quotes the method as 'titel', and older Rubies as `titel'.
    expect(last_response.body).to match(/\A## NoMethodError\n\n```\nundefined method ['`]titel'/)
    expect(last_response.body).to include("- Request: GET /books/247")
    expect(last_response.body).to include("### Source: #{File.basename(__FILE__)}:")
    expect(last_response.body).to include("title.titel")
  end

  it "evaluates source in the frame that raised" do
    skip "needs binding_of_caller" unless Hanami::Webconsole.bindings_available?

    get "/books/247", {}, "HTTP_ACCEPT" => "text/html"
    data = page_data

    post(
      data["evalPath"],
      JSON.generate("csrfToken" => data["csrfToken"], "index" => data["initialFrame"], "source" => "title"),
      "CONTENT_TYPE" => "application/json"
    )

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to include("output" => '"Ruby"', "error" => false)
  end
end
