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
    method_name: "GET",
    params: {"id" => "247"},
    session: {},
    cookies: {},
    headers: {"User-Agent" => "Mozilla/5.0"}
  )
    double(
      method_name: method_name,
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
    causes: [],
    frames: [frame],
    request: request_context,
    diagnostic: nil,
    text: "## NoMethodError"
  )
    double(
      id: "0-a1b2c3",
      generation: 0,
      exception_class: exception_class,
      message: message,
      detailed_extras: detailed_extras,
      status: status,
      actionable?: !diagnostic&.fix.nil?,
      diagnostic: diagnostic,
      causes: causes,
      frames: frames,
      request: request,
      to_text: text
    )
  end

  # A real wrapped diagnostic, around one that returns the given parts.
  def diagnostic(**parts)
    source = Class.new {
      parts.each { |name, value| define_method(name) { value } }
    }.new

    Hanami::Webconsole::Diagnostics::Wrapper.new(source)
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

    it "shows a name quoted the way Ruby quotes names as code" do
      html = described_class.render_html(error_page, nonce: "n0nce")

      expect(html).to include("undefined method <code>titel</code> for an instance of Book")
    end

    it "shows a backticked run as code" do
      html = described_class.render_html(error_page(message: "Add it to `config/routes.rb`."), nonce: "n0nce")

      expect(html).to include("Add it to <code>config/routes.rb</code>.")
    end

    it "leaves apostrophes in ordinary English as text" do
      message = "The slice's routes can't hold the users' paths"
      html = described_class.render_html(error_page(message: message), nonce: "n0nce")

      expect(html).to include("The slice&#39;s routes can&#39;t hold the users&#39; paths")
      expect(html).not_to include("<code>")
    end

    it "finds a quoted name among apostrophes" do
      message = "Can't find 'Books::Show' in the slice's container"
      html = described_class.render_html(error_page(message: message), nonce: "n0nce")

      expect(html).to include("Can&#39;t find <code>Books::Show</code> in the slice&#39;s container")
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

    it "renders a multi-line message as paragraphs and a list" do
      message = "Template `index' could not be found in paths:\n\n - app/templates\n - slices/main/templates"
      html = described_class.render_html(error_page(message: message), nonce: "n0nce")

      expect(html).to include("<p>Template <code>index</code> could not be found in paths:</p>")
      expect(html).to include("<ul><li>app/templates</li><li>slices/main/templates</li></ul>")
    end

    it "keeps a single line break in a message" do
      html = described_class.render_html(error_page(message: "First line\nSecond line"), nonce: "n0nce")

      expect(html).to include("<p>First line<br>\nSecond line</p>")
    end

    describe "a crash" do
      subject(:html) { described_class.render_html(error_page, nonce: "n0nce") }

      it "leads with the class name and message, and an open backtrace" do
        expect(html).to include(%(<h1 data-webconsole-headline>NoMethodError</h1>))
        expect(html).to include("data-webconsole-message")
        expect(html).to include("<div data-webconsole-shell>")
        expect(html).to include("#i-triangle-alert")
        expect(html).not_to match(/data-webconsole-workbench hidden/)
      end

      it "looks like a crash for a 404 with no diagnostic, and still shows the status" do
        html = described_class.render_html(error_page(status: 404), nonce: "n0nce")

        expect(html).to include("<div data-webconsole-shell>")
        expect(html).to include(%(<span class="status-code">404</span>))
        expect(html).to include(%(<span class="status-reason">Not Found</span>))
      end
    end

    describe "a diagnostic" do
      it "shows a title in place of the class name, and still shows the message under it" do
        page = error_page(
          diagnostic: diagnostic(title: "Missing method"),
          detailed_extras: ["Did you mean?  title"]
        )
        html = described_class.render_html(page, nonce: "n0nce")

        expect(html).to include(%(<h1 data-webconsole-headline>Missing method</h1>))
        expect(html).to include(%(data-webconsole-exception-class>NoMethodError</span>))
        expect(html).to include("undefined method <code>titel</code>")
        expect(html.index("data-webconsole-headline")).to be < html.index("data-webconsole-message")
        expect(html.index("data-webconsole-message")).to be < html.index(%(<div class="caret-box" data-webconsole-extras>))
      end

      it "shows the explanation after the message and its extras" do
        page = error_page(diagnostic: diagnostic(explanation: "Why."), detailed_extras: ["Did you mean?  title"])
        html = described_class.render_html(page, nonce: "n0nce")

        expect(html.index(%(<div class="caret-box" data-webconsole-extras>))).to be < html.index("data-webconsole-explanation")
      end

      it "shows an explanation as an extra paragraph" do
        html = described_class.render_html(
          error_page(diagnostic: diagnostic(explanation: "The route points to `books.show`.")), nonce: "n0nce"
        )

        expect(html).to include("data-webconsole-message")
        expect(html).to include("The route points to <code>books.show</code>.")
      end

      it "is not actionable without a fix" do
        html = described_class.render_html(
          error_page(diagnostic: diagnostic(explanation: "Why it happened.")), nonce: "n0nce"
        )

        expect(html).to include("<div data-webconsole-shell>")
        expect(html).not_to include(%(<div class="fix" data-webconsole-fix>))
      end

      it "is actionable with a fix, and collapses the backtrace" do
        html = described_class.render_html(
          error_page(diagnostic: diagnostic(fix: "Did you mean `/books/:id`?")), nonce: "n0nce"
        )

        expect(html).to include("<div data-webconsole-shell data-actionable>")
        expect(html).to include("#i-wrench")
        expect(html).to match(/data-webconsole-workbench hidden/)
      end

      it "heads an unnamed fix generically" do
        html = described_class.render_html(error_page(diagnostic: diagnostic(fix: "Do this.")), nonce: "n0nce")

        expect(html).to include("<h2>Fix it</h2>")
        expect(html).to include("<p>Do this.</p>")
      end

      it "heads a named fix with its name" do
        html = described_class.render_html(
          error_page(diagnostic: diagnostic(fix: {name: "Add a route", text: "Add it."})), nonce: "n0nce"
        )

        expect(html).to include("<h2>Add a route</h2>")
        expect(html).not_to include(%(class="btn-primary" data-webconsole-run))
      end

      it "shows a shell block as a command, and a Ruby block as highlighted code" do
        text = "Run:\n\n```sh\nbundle exec hanami db migrate\n```\n\nOr add:\n\n```ruby\nget \"/x\", to: \"...\"\n```"
        html = described_class.render_html(error_page(diagnostic: diagnostic(fix: text)), nonce: "n0nce")

        expect(html).to include(%(<span class="prompt">$</span><code data-webconsole-command>bundle exec hanami db migrate</code>))
        expect(html).to include(%(<pre class="snippet" data-webconsole-snippet data-webconsole-highlight>get &quot;/x&quot;, to: &quot;...&quot;</pre>))
        expect(html.scan(%(data-webconsole-copy="command")).length).to eq(1)
        expect(html.scan(%(data-webconsole-copy="snippet")).length).to eq(1)
      end

      it "escapes diagnostic text" do
        page = error_page(diagnostic: diagnostic(title: xss, explanation: xss, fix: {name: xss, text: "```sh\n#{xss}\n```"}))
        html = described_class.render_html(page, nonce: "n0nce")

        expect(html).not_to include(xss)
      end

      describe "with a fix that can run" do
        it "puts the fix's name on the button, not in a heading" do
          page = error_page(diagnostic: diagnostic(fix: {name: "Generate action", text: "Generate it."}, run_fix: "done"))
          html = described_class.render_html(page, nonce: "n0nce")

          expect(html).to match(%r{data-webconsole-run>\s*<svg[^>]*><use href="#i-play"/></svg><span class="label">Generate action</span>})
          expect(html).not_to include("<h2>Generate action</h2>")
          expect(html).to include("data-webconsole-run-output")
        end

        it "labels the button generically for an unnamed fix" do
          html = described_class.render_html(error_page(diagnostic: diagnostic(fix: "Do it.", run_fix: "done")), nonce: "n0nce")

          expect(html).to include(%(<span class="label">Run this fix</span>))
          expect(html).to include("<h2>Fix it</h2>")
        end

        it "tells the page where to run it, and whether reloading retries the request" do
          page = error_page(diagnostic: diagnostic(fix: "Do it.", run_fix: "done"))

          expect(payload(described_class.render_html(page, nonce: "n0nce"))).to include(
            "runPath" => "/_hanami/webconsole/0-a1b2c3/run", "retryable" => true
          )
        end

        it "doesn't retry a request that wasn't a GET" do
          page = error_page(diagnostic: diagnostic(fix: "Do it.", run_fix: "done"), request: request_context(method_name: "POST"))

          expect(payload(described_class.render_html(page, nonce: "n0nce"))["retryable"]).to be(false)
        end
      end

      it "shows a two-column table as a normal panel, before the request panels" do
        page = error_page(diagnostic: diagnostic(dataset: {title: "Pending", rows: {"a.rb" => "1", "b.rb" => "2"}}))
        html = described_class.render_html(page, nonce: "n0nce")

        expect(html.index(%(data-webconsole-context-panel="Pending"))).to be < html.index(%(data-webconsole-context-panel="Request"))
        expect(html).to include(%(<div class="ctx-panel" data-webconsole-context-panel="Pending">))
        expect(html).not_to include("<thead>")
      end

      it "shows a table with more columns across the full width, with its headings" do
        dataset = {title: "Routes", columns: ["Method", "Path", "Endpoint"], rows: [["GET", "/books", "books.index"]]}
        html = described_class.render_html(error_page(diagnostic: diagnostic(dataset:)), nonce: "n0nce")

        expect(html).to include(%(<div class="ctx-panel is-wide" data-webconsole-context-panel="Routes">))
        expect(html).to include(%(<th scope="col">Endpoint</th>))
        expect(html).to include(%(<td class="k-val" data-webconsole-cell>books.index</td>))
        expect(html).to include("#i-route")
      end
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
          title: "Title", fix: {name: "Generate action", text: "Generate it."}, run_fix: "done",
          dataset: {title: "Actions", rows: ["books.index"]}
        )
      )
      json = JSON.parse(described_class.render_json(page))

      expect(json["actionable"]).to be(true)
      expect(json["diagnostic"]).to eq(
        "title" => "Title",
        "explanation" => nil,
        "fix" => {"name" => "Generate action", "text" => "Generate it.", "runnable" => true},
        "dataset" => {"title" => "Actions", "columns" => [], "rows" => [["books.index"]]}
      )
    end
  end
end
