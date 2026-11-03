# frozen_string_literal: true

require "json"

RSpec.describe Hanami::Webconsole::Rendering::HTML do
  include ErrorPageDoubles

  def html_for(page, nonce: "n0nce", **options)
    described_class.new(page, nonce:, **options).to_s
  end

  # The JSON island: the data the page's script reads, in its own `<script>` tag.
  def json_island(html)
    html[%r{<script type="application/json" data-webconsole-frames>(.*?)</script>}m, 1]
  end

  def page_data(html)
    JSON.parse(json_island(html))
  end

  it "renders the exception class, message and request" do
    html = html_for(error_page)

    expect(html).to start_with("<!DOCTYPE html>")
    expect(html).to include("NoMethodError")
    expect(html).to include("data-webconsole-exception-class")
    # Code and reason are separate spans so narrow screens can drop the reason.
    expect(html).to include(%(<span class="status-code">500</span>))
    expect(html).to include(%(<span class="status-reason">Internal Server Error</span>))
    expect(html).to include("/books/247")
  end

  it "escapes the exception message" do
    html = html_for(error_page(message: xss))

    expect(html).not_to include(xss)
    expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
  end

  it "shows a name quoted in a message as code, keeping its quotes" do
    html = html_for(error_page)

    expect(html).to include("undefined method <code>&#39;titel&#39;</code> for an instance of Book")
  end

  it "shows a name quoted in a diagnostic's text as code, without its quotes" do
    html = html_for(error_page(diagnostic: diagnostic(explanation: "Define 'show' in `config/routes.rb`.")))

    expect(html).to include("Define <code>show</code> in <code>config/routes.rb</code>.")
  end

  it "leaves apostrophes in ordinary English as text" do
    message = "The slice's routes can't hold the users' paths"
    html = html_for(error_page(message:))

    expect(html).to include("The slice&#39;s routes can&#39;t hold the users&#39; paths")
    expect(html).not_to include("<code>")
  end

  it "finds a quoted name among apostrophes" do
    message = "Can't find 'Books::Show' in the slice's container"
    html = html_for(error_page(message:))

    expect(html).to include("Can&#39;t find <code>&#39;Books::Show&#39;</code> in the slice&#39;s container")
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

    html = html_for(page)

    expect(html).not_to include(xss)
    expect(html).not_to include("</script>alert")
    # The JSON island keeps the payload out of HTML syntax entirely.
    expect(page_data(html)["frames"][0]["src"]).to eq([xss])
    expect(page_data(html)["frames"][0]["locals"]).to eq([[xss, xss, xss]])
  end

  it "escapes markup in the copy-as-text payload" do
    html = html_for(error_page(message: xss))

    expect(html).not_to include(xss)
    expect(page_data(html)["text"]).to include(xss)
  end

  it "puts the nonce on the style tag and on the script tag" do
    html = html_for(error_page, nonce: "n0nce")

    expect(html).to include(%(<style nonce="n0nce">))
    expect(html).to include(%(<script nonce="n0nce">))
  end

  it "escapes the nonce" do
    html = html_for(error_page, nonce: %("><script>x</script>))

    expect(html).not_to include("<script>x</script>")
  end

  it "uses no inline event handlers" do
    html = html_for(error_page)

    expect(html).not_to match(/\bon[a-z]+\s*=/i)
  end

  it "uses no inline style attributes" do
    html = html_for(error_page)

    expect(html).not_to match(/\sstyle\s*=/)
  end

  it "embeds the frames, the eval endpoint and the CSRF cookie name" do
    html = html_for(error_page)
    data = page_data(html)

    expect(data["frames"].length).to eq(1)
    expect(data["frames"][0]).to include(
      "kind" => "app",
      "line" => 11,
      "displayPath" => "lib/bookshelf/repositories/book_repo.rb",
      "start" => 10,
      "binding" => false
    )
    expect(data["evalPath"]).to eq("/_hanami/webconsole/0-a1b2c3/eval")
    expect(data["csrfCookie"]).to eq(Hanami::Webconsole::CSRF_COOKIE_NAME)
    expect(data["initialFrame"]).to eq(0)
  end

  it "embeds the CSRF token for the console's double submit" do
    html = html_for(error_page, csrf_token: "t0ken")

    expect(page_data(html)["csrfToken"]).to eq("t0ken")
  end

  it "escapes < > and & in the JSON island so a string can never close the script" do
    island = json_island(html_for(error_page(message: xss)))

    expect(island).not_to include("<")
    expect(island).not_to include(">")
    expect(island).not_to include("&")
  end

  it "links each frame to the configured editor" do
    html = html_for(error_page)

    expect(page_data(html)["frames"][0]["editorUrl"]).to eq(
      Hanami::Webconsole::Editor.from_env.url(
        "/app/lib/bookshelf/repositories/book_repo.rb", 11
      )
    )
  end

  it "reports a frame with no readable source" do
    page = error_page(frames: [frame(source: nil)])
    data = page_data(html_for(page))

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

    expect(page_data(html_for(page))["initialFrame"]).to eq(1)
  end

  it "renders a page with no frames at all" do
    html = html_for(error_page(frames: []))

    expect(html).to include("data-webconsole-frames-empty")
  end

  it "renders the detailed_message extras with the caret highlighted" do
    page = error_page(detailed_extras: ["  book.titel", "       ^^^^^"])
    html = html_for(page)

    expect(html).to include("data-webconsole-extras")
    expect(html).to include(%(<span class="caret">       ^^^^^</span>))
  end

  it "shows a multi-line message as written" do
    message = "Template `index' could not be found in paths:\n\n - app/templates\n - slices/main/templates"
    html = html_for(error_page(message:))

    expect(html).to include(
      %(<pre class="lede message" data-webconsole-message>Template <code>`index&#39;</code> could not be found in paths:\n\n) +
        " - app/templates\n - slices/main/templates</pre>"
    )
  end

  it "keeps the alignment of a message, since quoted names keep their quotes" do
    message = "app/x.rb:3: syntax error found\n> 3 | go 'a', `b`\n    |              ^ here"
    html = html_for(error_page(message:))

    expect(html).to include(
      "app/x.rb:3: syntax error found\n&gt; 3 | go <code>&#39;a&#39;</code>, <code>`b`</code>\n    |              ^ here"
    )
  end

  describe "a crash" do
    it "leads with the class name and message, and an open backtrace" do
      html = html_for(error_page)

      expect(html).to include(%(<h1 data-webconsole-headline>NoMethodError</h1>))
      expect(html).to include("data-webconsole-message")
      expect(html).to include("<div data-webconsole-shell>")
      expect(html).to include("#i-triangle-alert")
      expect(html).not_to match(/data-webconsole-workbench hidden/)
    end

    it "looks like a crash for a 404 with no diagnostic, and still shows the status" do
      html = html_for(error_page(status: 404))

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
      html = html_for(page)

      expect(html).to include(%(<h1 data-webconsole-headline>Missing method</h1>))
      expect(html).to include(%(data-webconsole-exception-class>NoMethodError</span>))
      expect(html).to include("undefined method <code>&#39;titel&#39;</code>")
      expect(html.index("data-webconsole-headline")).to be < html.index("data-webconsole-message")
      expect(html.index("data-webconsole-message")).to be < html.index(%(<div class="caret-box" data-webconsole-extras>))
    end

    it "shows the explanation after the message and its extras, as formatted text" do
      page = error_page(
        diagnostic: diagnostic(explanation: "The route points to `books.show`."),
        detailed_extras: ["Did you mean?  title"]
      )
      html = html_for(page)

      expect(html.index(%(<div class="caret-box" data-webconsole-extras>))).to be < html.index("data-webconsole-explanation")
      expect(html).to include("The route points to <code>books.show</code>.")
    end

    it "is not actionable without a fix" do
      html = html_for(error_page(diagnostic: diagnostic(explanation: "Why it happened.")))

      expect(html).to include("<div data-webconsole-shell>")
      expect(html).not_to include(%(<div class="fix" data-webconsole-fix>))
    end

    it "is actionable with a fix, and collapses the backtrace" do
      html = html_for(error_page(diagnostic: diagnostic(fix: "Did you mean `/books/:id`?")))

      expect(html).to include("<div data-webconsole-shell data-actionable>")
      expect(html).to include("#i-wrench")
      expect(html).to match(/data-webconsole-workbench hidden/)
    end

    it "heads an unnamed fix generically" do
      html = html_for(error_page(diagnostic: diagnostic(fix: "Do this.")))

      expect(html).to include("<h2>Fix it</h2>")
      expect(html).to include("<p>Do this.</p>")
    end

    it "heads a named fix with its name" do
      html = html_for(error_page(diagnostic: diagnostic(fix: {name: "Add a route", text: "Add it."})))

      expect(html).to include("<h2>Add a route</h2>")
      expect(html).not_to include(%(class="btn-primary" data-webconsole-run))
    end

    it "shows a shell block as a command, and a Ruby block as highlighted code" do
      text = "Run:\n\n```sh\nbundle exec hanami db migrate\n```\n\nOr add:\n\n```ruby\nget \"/x\", to: \"...\"\n```"
      html = html_for(error_page(diagnostic: diagnostic(fix: text)))

      expect(html).to include(%(<span class="prompt">$</span><code data-webconsole-command>bundle exec hanami db migrate</code>))
      expect(html).to include(%(<pre class="snippet" data-webconsole-snippet data-webconsole-highlight>get &quot;/x&quot;, to: &quot;...&quot;</pre>))
      expect(html.scan(%(data-webconsole-copy="command")).length).to eq(1)
      expect(html.scan(%(data-webconsole-copy="snippet")).length).to eq(1)
    end

    it "escapes diagnostic text" do
      page = error_page(
        diagnostic: diagnostic(title: xss, explanation: xss, fix: {name: xss, text: "```sh\n#{xss}\n```"})
      )
      html = html_for(page)

      expect(html).not_to include(xss)
    end

    describe "with a fix that can run" do
      def page_with_runnable_fix(fix, **page_options)
        error_page(diagnostic: diagnostic(fix:, run_fix: "done"), **page_options)
      end

      it "puts the fix's name on the button, not in a heading" do
        html = html_for(page_with_runnable_fix({name: "Generate action", text: "Generate it."}))

        expect(html).to match(
          %r{data-webconsole-run>\s*<svg[^>]*><use href="#i-play"/></svg><span class="label">Generate action</span>}
        )
        expect(html).not_to include("<h2>Generate action</h2>")
        expect(html).to include("data-webconsole-run-output")
      end

      it "marks the button of a destructive fix, and no other" do
        destructive = page_with_runnable_fix({text: "Roll back.", destructive: true})
        safe = page_with_runnable_fix("Do it.")

        expect(html_for(destructive)).to include("data-webconsole-run data-destructive>")
        expect(html_for(safe)).to include("data-webconsole-run>")
      end

      it "labels the button generically for an unnamed fix" do
        html = html_for(page_with_runnable_fix("Do it."))

        expect(html).to include(%(<span class="label">Run this fix</span>))
        expect(html).to include("<h2>Fix it</h2>")
      end

      it "tells the page where to run it, and whether reloading retries the request" do
        data = page_data(html_for(page_with_runnable_fix("Do it.")))

        expect(data).to include("runPath" => "/_hanami/webconsole/0-a1b2c3/run", "retryable" => true)
      end

      it "doesn't retry a request that wasn't a GET" do
        page = page_with_runnable_fix("Do it.", request: request_context(method_name: "POST"))

        expect(page_data(html_for(page))["retryable"]).to be(false)
      end
    end

    it "shows a two-column table as a normal panel, before the request panels" do
      page = error_page(
        diagnostic: diagnostic(dataset: {title: "Pending", rows: {"a.rb" => "1", "b.rb" => "2"}})
      )
      html = html_for(page)

      expect(html.index(%(data-webconsole-context-panel="Pending"))).to be < html.index(%(data-webconsole-context-panel="Request"))
      expect(html).to include(%(<div class="ctx-panel" data-webconsole-context-panel="Pending">))
      expect(html).not_to include("<thead>")
    end

    it "shows a table with more columns across the full width, with its headings" do
      dataset = {title: "Routes", columns: ["Method", "Path", "Endpoint"], rows: [["GET", "/books", "books.index"]]}
      html = html_for(error_page(diagnostic: diagnostic(dataset:)))

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
    html = html_for(page)

    expect(html).to include(%(data-webconsole-context-panel="Request"))
    expect(html).to include(%(data-webconsole-context-panel="Params"))
    expect(html).to include(%(data-webconsole-context-panel="Session"))
    expect(html).to include(%(data-webconsole-context-panel="Cookies"))
    expect(html).to include(%(data-webconsole-context-panel="Headers"))
    expect(html).to include(%(class="k-val filtered"))
  end

  # Without a UTF-8 locale (`LANG` unset, as in many Docker images), Ruby reads files as US-ASCII.
  describe "under a default external encoding that isn't UTF-8" do
    around do |example|
      verbose = $VERBOSE
      external = Encoding.default_external
      cached = %i[@template @assets].to_h { |name| [name, described_class.instance_variable_get(name)] }

      # Read the template and assets again, under the new encoding
      cached.each_key { |name| described_class.instance_variable_set(name, nil) }

      begin
        # Setting the encoding warns in verbose mode
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII
        example.run
      ensure
        Encoding.default_external = external
        $VERBOSE = verbose
        cached.each { |name, value| described_class.instance_variable_set(name, value) }
      end
    end

    it "renders the page, with its non-ASCII template and assets intact" do
      html = html_for(error_page)

      expect(html.encoding).to eq(Encoding::UTF_8)
      expect(html).not_to be_ascii_only
    end
  end
end
