# frozen_string_literal: true

require "hanami/webconsole/renderer"
require "json"

# Doubles here mirror the signatures in CONTRACTS.md, so this spec runs without ErrorPage, Frame or
# RequestContext being implemented yet.
RSpec.describe Hanami::Webconsole::Renderer do
  def xss
    "<script>alert(1)</script>"
  end

  def variable(name, class_name, value)
    double(name: name, class_name: class_name, value: value)
  end

  def excerpt(lines, first_lineno: 10, highlight_lineno: 11)
    double(
      path: "/app/lib/bookshelf/repositories/book_repo.rb",
      first_lineno: first_lineno,
      lines: lines,
      highlight_lineno: highlight_lineno
    )
  end

  def frame(
    kind: :app,
    path: "/app/lib/bookshelf/repositories/book_repo.rb",
    display_path: "lib/bookshelf/repositories/book_repo.rb",
    lineno: 11,
    label: "Bookshelf::Repositories::BookRepo#find",
    source: excerpt(["def find(id)", "  books.by_pk(id).one!", "end"]),
    locals: [variable("id", "Integer", "247")],
    instance_vars: [],
    frame_binding: nil
  )
    double(
      kind: kind,
      app?: kind == :app,
      path: path,
      display_path: display_path,
      lineno: lineno,
      label: label,
      source: source,
      locals: locals,
      instance_vars: instance_vars,
      binding: frame_binding,
      receiver_inspect: "#<Bookshelf::Repositories::BookRepo>"
    )
  end

  def request_context(
    params: {"id" => "247"},
    session: {},
    cookies: {},
    headers: {"User-Agent" => "Mozilla/5.0"}
  )
    double(
      method_name: "GET",
      path: "/books/247",
      format: "text/html",
      ip: "127.0.0.1",
      params: params,
      session: session,
      cookies: cookies,
      headers: headers,
      slice_name: "Bookshelf",
      route: "GET /books/:id → books.show",
      action_name: "Bookshelf::Actions::Books::Show"
    )
  end

  def error_page(
    exception_class: "NoMethodError",
    message: "undefined method 'titel' for an instance of Book",
    detailed_extras: [],
    status: 500,
    severity: :crash,
    causes: [],
    frames: [frame],
    request: request_context,
    presenter: nil,
    text: "## NoMethodError"
  )
    double(
      id: "0-a1b2c3",
      generation: 0,
      exception_class: exception_class,
      message: message,
      detailed_extras: detailed_extras,
      status: status,
      severity: severity,
      causes: causes,
      frames: frames,
      request: request,
      presenter: presenter,
      to_text: text
    )
  end

  def payload(html)
    JSON.parse(html[%r{<script type="application/json" data-webconsole-frames>(.*?)</script>}m, 1])
  end

  describe ".render_html" do
    it "renders the exception class, message and request" do
      html = described_class.render_html(error_page, nonce: "n0nce")

      expect(html).to start_with("<!DOCTYPE html>")
      expect(html).to include("NoMethodError")
      expect(html).to include("data-webconsole-exception-class")
      # Code and reason are separate spans so narrow screens can drop the reason.
      expect(html).to include(%(<span class="status-code">500</span>))
      expect(html).to include(%(<span class="status-reason">Internal Server Error</span>))
      expect(html).to include("/books/247")
    end

    it "escapes the exception message" do
      html = described_class.render_html(error_page(message: xss), nonce: "n0nce")

      expect(html).not_to include(xss)
      expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    end

    it "escapes source lines, variables and request values" do
      page = error_page(
        frames: [
          frame(
            source: excerpt([xss]),
            locals: [variable(xss, xss, xss)],
            instance_vars: [variable("@a", "String", xss)]
          )
        ],
        request: request_context(
          params: {xss => xss},
          headers: {xss => xss},
          cookies: {"session" => xss}
        )
      )

      html = described_class.render_html(page, nonce: "n0nce")

      expect(html).not_to include(xss)
      expect(html).not_to include("</script>alert")
      # The JSON island keeps the payload out of HTML syntax entirely.
      expect(payload(html)["frames"][0]["src"]).to eq([xss])
      expect(payload(html)["frames"][0]["locals"]).to eq([[xss, xss, xss]])
    end

    it "escapes markup in the copy-as-text payload" do
      html = described_class.render_html(error_page(text: "## #{xss}"), nonce: "n0nce")

      expect(html).not_to include(xss)
      expect(payload(html)["text"]).to eq("## #{xss}")
    end

    it "puts the nonce on the style tag and on the script tag" do
      html = described_class.render_html(error_page, nonce: "n0nce")

      expect(html).to include(%(<style nonce="n0nce">))
      expect(html).to include(%(<script nonce="n0nce">))
    end

    it "escapes the nonce" do
      html = described_class.render_html(error_page, nonce: %("><script>x</script>))

      expect(html).not_to include("<script>x</script>")
    end

    it "uses no inline event handlers" do
      html = described_class.render_html(error_page, nonce: "n0nce")

      expect(html).not_to match(/\bon[a-z]+\s*=/i)
    end

    it "uses no inline style attributes" do
      html = described_class.render_html(error_page, nonce: "n0nce")

      expect(html).not_to match(/\sstyle\s*=/)
    end

    it "embeds the frames, the eval endpoint and the CSRF cookie name" do
      html = described_class.render_html(error_page, nonce: "n0nce")
      data = payload(html)

      expect(data["frames"].length).to eq(1)
      expect(data["frames"][0]).to include(
        "kind" => "app",
        "line" => 11,
        "displayPath" => "lib/bookshelf/repositories/book_repo.rb",
        "start" => 10,
        "binding" => false
      )
      expect(data["evalPath"]).to eq("/_hanami/webconsole/0-a1b2c3/eval")
      expect(data["csrfCookie"]).to eq(described_class::CSRF_COOKIE_NAME)
      expect(data["initialFrame"]).to eq(0)
    end

    it "embeds the CSRF token for the console's double submit" do
      html = described_class.render_html(error_page, nonce: "n0nce", csrf_token: "t0ken")

      expect(payload(html)["csrfToken"]).to eq("t0ken")
    end

    it "renders without a CSRF token" do
      expect(payload(described_class.render_html(error_page, nonce: "n0nce"))["csrfToken"]).to be_nil
    end

    it "escapes < > and & in the JSON island so a string can never close the script" do
      html = described_class.render_html(error_page(message: xss), nonce: "n0nce")
      island = html[%r{<script type="application/json" data-webconsole-frames>(.*?)</script>}m, 1]

      expect(island).not_to include("<")
      expect(island).not_to include(">")
      expect(island).not_to include("&")
    end

    it "links each frame to the configured editor" do
      html = described_class.render_html(error_page, nonce: "n0nce")

      expect(payload(html)["frames"][0]["editorUrl"]).to eq(
        Hanami::Webconsole::Editor.from_env.url(
          "/app/lib/bookshelf/repositories/book_repo.rb", 11
        )
      )
    end

    it "reports a frame with no readable source" do
      page = error_page(frames: [frame(source: nil)])
      data = payload(described_class.render_html(page, nonce: "n0nce"))

      expect(data["frames"][0]["src"]).to be_nil
      expect(data["frames"][0]["start"]).to be_nil
    end

    it "starts on the first application frame" do
      page = error_page(
        frames: [
          frame(kind: :gem, display_path: "rack-3.1.8/lib/rack/lint.rb"),
          frame(kind: :app)
        ]
      )

      expect(payload(described_class.render_html(page, nonce: "n0nce"))["initialFrame"]).to eq(1)
    end

    it "renders a page with no frames at all" do
      html = described_class.render_html(error_page(frames: []), nonce: "n0nce")

      expect(html).to include("data-webconsole-frames-empty")
    end

    it "renders the detailed_message extras with the caret highlighted" do
      page = error_page(detailed_extras: ["  book.titel", "       ^^^^^"])
      html = described_class.render_html(page, nonce: "n0nce")

      expect(html).to include("data-webconsole-extras")
      expect(html).to include(%(<span class="caret">       ^^^^^</span>))
    end

    it "renders a presenter's fix card, escaped" do
      presenter = double(
        headline: "Run the pending migrations",
        lede: "Your schema is behind #{xss}",
        command: "bundle exec hanami db migrate #{xss}",
        snippet: nil,
        items: ["20250811103012_create_books.rb"],
        note: nil,
        suggestions: [],
        context_panels: []
      )
      html = described_class.render_html(
        error_page(presenter: presenter, severity: :actionable), nonce: "n0nce"
      )

      expect(html).to include("data-webconsole-fix")
      expect(html).to include("Run the pending migrations")
      expect(html).to include("20250811103012_create_books.rb")
      expect(html).not_to include(xss)
      expect(html).to include(%(data-severity="actionable"))
    end

    it "maps a 404 to the notfound severity and collapses the backtrace" do
      html = described_class.render_html(
        error_page(severity: :not_found, status: 404), nonce: "n0nce"
      )

      expect(html).to include(%(data-severity="notfound"))
      expect(html).to include(%(<span class="status-code">404</span>))
      expect(html).to include(%(<span class="status-reason">Not Found</span>))
      expect(html).to match(/data-webconsole-workbench hidden/)
    end

    it "renders a context panel per request section" do
      page = error_page(
        request: request_context(session: {"user_id" => "12"}, cookies: {"_session" => "[FILTERED]"})
      )
      html = described_class.render_html(page, nonce: "n0nce")

      expect(html).to include(%(data-webconsole-context-panel="Request"))
      expect(html).to include(%(data-webconsole-context-panel="Params"))
      expect(html).to include(%(data-webconsole-context-panel="Session"))
      expect(html).to include(%(data-webconsole-context-panel="Cookies"))
      expect(html).to include(%(data-webconsole-context-panel="Headers"))
      expect(html).to include(%(class="k-val filtered"))
    end

    it "reads and compiles the template only once" do
      described_class.render_html(error_page, nonce: "n0nce")

      expect(described_class.send(:template)).to be(described_class.send(:template))
    end
  end

  describe ".render_text" do
    it "delegates to the page" do
      expect(described_class.render_text(error_page(text: "## Boom"))).to eq("## Boom")
    end
  end

  describe ".render_json" do
    it "renders the error as JSON" do
      json = JSON.parse(described_class.render_json(error_page(causes: ["ArgumentError"])))

      expect(json).to include(
        "error" => "NoMethodError",
        "status" => 500,
        "severity" => "crash",
        "causes" => ["ArgumentError"]
      )
      expect(json["backtrace"].first).to eq(
        "/app/lib/bookshelf/repositories/book_repo.rb:11:in 'Bookshelf::Repositories::BookRepo#find'"
      )
      expect(json["request"]).to include("method" => "GET", "path" => "/books/247")
    end
  end
end
