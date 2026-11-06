# frozen_string_literal: true

require "json"

# The middleware runs with its real collaborators (the registry, the renderers and the console),
# except for the page itself. A double stands in for the page, so each spec controls exactly what
# the page holds, without building one from a real exception.
RSpec.describe Hanami::Webconsole::Middleware, type: :rack do
  include ErrorPageDoubles

  subject(:middleware) { described_class.new(inner_app, slice) }

  let(:app) { middleware }

  # --- the wrapped app -------------------------------------------------------------------------

  let(:raised) { nil }

  let(:inner_app) do
    exception = raised

    lambda { |_env|
      raise exception if exception

      [200, {"content-type" => "text/plain"}, ["from the app"]]
    }
  end

  # --- config ----------------------------------------------------------------------------------

  # Only passed through to the page, which is stubbed below.
  let(:config) { double("Config") }
  let(:slice) { double("Slice", config:, app: nil) }

  # --- the page --------------------------------------------------------------------------------

  let(:page) {
    error_page(
      exception_class: "RuntimeError",
      message: "boom",
      frames: [
        frame(
          locals: [variable("id", "String", '"247"')],
          instance_vars: [variable("@repo", "BookRepo", "#<BookRepo>")],
          # A real binding, so the console can evaluate source in it.
          frame_binding: binding
        )
      ]
    )
  }

  let(:registry) { Hanami::Webconsole::Registry.new }

  before do
    allow(Hanami::Webconsole::ErrorPage).to receive(:new).and_return(page)
    allow(Hanami::Webconsole::Registry).to receive(:new).and_return(registry)
  end

  # --- helpers ---------------------------------------------------------------------------------

  let(:csrf_token) { "9d3a4a2e-0000-4000-8000-000000000000" }

  def console_post(path, payload, env = {})
    post(
      path,
      JSON.generate(payload),
      {"CONTENT_TYPE" => "application/json"}.merge(env)
    )
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def set_cookies
    Array(last_response.headers["set-cookie"]).flat_map { |value| value.split("\n") }
  end

  describe "IP allowlist" do
    it "allows loopback IPv4" do
      get "/", {}, "REMOTE_ADDR" => "127.0.0.1"

      expect(last_response.status).to eq(200)
    end

    it "allows any address in 127.0.0.0/8" do
      get "/", {}, "REMOTE_ADDR" => "127.9.9.9", "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(200)
    end

    it "allows IPv6 loopback, including a zone id" do
      get "/", {}, "REMOTE_ADDR" => "::1%lo0", "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(200)
    end

    it "allows a request with no usable REMOTE_ADDR, as better_errors does" do
      get "/", {}, "REMOTE_ADDR" => ""

      expect(last_response.status).to eq(200)
    end

    it "denies an unparseable address rather than raising" do
      expect { get "/", {}, "REMOTE_ADDR" => "not-an-ip" }.not_to raise_error

      expect(last_response.body).to eq("from the app")
    end

    context "when the address is not allowed" do
      let(:remote) { {"REMOTE_ADDR" => "203.0.113.10", "HTTP_ACCEPT" => "text/html"} }

      it "passes the app's response through untouched" do
        get "/", {}, remote

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("from the app")
        expect(last_response.headers["content-security-policy"]).to be_nil
        expect(set_cookies).to be_empty
      end

      context "and the app raises" do
        let(:raised) { RuntimeError.new("boom") }

        it "does not render an error page" do
          expect { get "/", {}, remote }.to raise_error(RuntimeError, "boom")

          expect(Hanami::Webconsole::ErrorPage).not_to have_received(:new)
          expect(registry.size).to eq(0)
        end
      end

      it "does not serve the console endpoints" do
        registry.put(page)
        set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}"

        console_post(
          "/_hanami/webconsole/#{page.id}/eval",
          {"csrfToken" => csrf_token, "index" => 0, "source" => "1 + 1"},
          remote
        )

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("from the app")
      end
    end
  end

  describe "rendering the error page" do
    let(:raised) { RuntimeError.new("boom") }

    it "renders HTML" do
      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(500)
      expect(last_response.headers["content-type"]).to eq("text/html; charset=utf-8")
      expect(last_response.body).to include("RuntimeError")
    end

    it "builds the page and stores it in the registry" do
      get "/", {}, "HTTP_ACCEPT" => "text/html"

      # No id: the page makes its own random id (see the ErrorPage specs).
      expect(Hanami::Webconsole::ErrorPage).to have_received(:new).with(
        exception: raised,
        env: hash_including("PATH_INFO" => "/"),
        config:,
        slice:,
        bindings: anything
      )
      expect(registry.fetch(page.id)).to be(page)
    end

    # The mapping from `config.render_error_responses` is in ErrorPage#status, and specced there.
    it "responds with the page's status" do
      allow(page).to receive(:status).and_return(404)

      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(404)
    end

    it "rescues non-StandardError exceptions" do
      allow(inner_app).to receive(:call).and_raise(NotImplementedError.new("nope"))

      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(500)
      expect(Hanami::Webconsole::ErrorPage).to have_received(:new).once
    end

    it "falls back to plain text when the page itself cannot be rendered" do
      allow(Hanami::Webconsole::ErrorPage).to receive(:new).and_raise(ArgumentError.new("bad contract"))

      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(500)
      expect(last_response.headers["content-type"]).to eq("text/plain; charset=utf-8")
      expect(last_response.body).to include("RuntimeError: boom")
      expect(last_response.body).to include("ArgumentError: bad contract")
    end

    describe "Content-Security-Policy" do
      it "is strict and carries a per-response nonce" do
        get "/", {}, "HTTP_ACCEPT" => "text/html"

        csp = last_response.headers["content-security-policy"]
        nonce = "[A-Za-z0-9+/=]+"

        expect(csp).to match(
          Regexp.new(
            "\\Adefault-src 'none'; " \
            "script-src 'nonce-(?<nonce>#{nonce})'; " \
            "style-src 'nonce-\\k<nonce>'; " \
            "img-src data:; " \
            "connect-src 'self'\\z"
          )
        )
      end

      it "uses a fresh nonce for every response" do
        get "/", {}, "HTTP_ACCEPT" => "text/html"
        first = last_response.headers["content-security-policy"]

        get "/", {}, "HTTP_ACCEPT" => "text/html"

        expect(last_response.headers["content-security-policy"]).not_to eq(first)
      end

      it "puts the nonce on the page" do
        get "/", {}, "HTTP_ACCEPT" => "text/html"

        nonce = last_response.headers["content-security-policy"][/'nonce-([^']+)'/, 1]

        expect(last_response.body).to include(%(<script nonce="#{nonce}">))
      end
    end

    describe "the CSRF cookie" do
      # Lax, not strict: Safari sends no strict cookies when a page is opened by typing its URL, so
      # the page would get a new cookie, breaking the console on every other open error page.
      it "is set, httponly and same-site lax, when not already present" do
        get "/", {}, "HTTP_ACCEPT" => "text/html"

        cookie = set_cookies.find { |value| value.start_with?("Hanami-Webconsole-CSRF-Token=") }

        expect(cookie).not_to be_nil
        expect(cookie).to match(/httponly/i)
        expect(cookie).to match(/samesite=lax/i)
        expect(cookie).to match(%r{path=/})
      end

      it "is not reset when the browser already has one, and its token goes on the page" do
        set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}"

        get "/", {}, "HTTP_ACCEPT" => "text/html"

        expect(set_cookies).to be_empty
        expect(last_response.body).to include(%("csrfToken":"#{csrf_token}"))
      end
    end

    describe "content negotiation" do
      it "renders JSON for Accept: application/json" do
        get "/", {}, "HTTP_ACCEPT" => "application/json"

        expect(last_response.status).to eq(500)
        expect(last_response.headers["content-type"]).to eq("application/json; charset=utf-8")
        expect(json_body).to include("error" => "RuntimeError", "message" => "boom")
      end

      it "renders text for Accept: text/plain" do
        get "/", {}, "HTTP_ACCEPT" => "text/plain"

        expect(last_response.headers["content-type"]).to eq("text/plain; charset=utf-8")
        expect(last_response.body).to start_with("## RuntimeError\n\n```\nboom\n```\n")
      end

      it "renders text for an XHR that would otherwise accept HTML" do
        get "/", {}, "HTTP_ACCEPT" => "text/html", "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest"

        expect(last_response.headers["content-type"]).to eq("text/plain; charset=utf-8")
        expect(last_response.body).to start_with("## RuntimeError\n\n```\nboom\n```\n")
      end

      it "renders HTML for a browser Accept header" do
        get "/", {}, "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

        expect(last_response.headers["content-type"]).to eq("text/html; charset=utf-8")
      end
    end
  end

  describe "console endpoints" do
    let(:eval_path) { "/_hanami/webconsole/#{page.id}/eval" }
    let(:variables_path) { "/_hanami/webconsole/#{page.id}/variables" }

    before do
      allow(Hanami::Webconsole).to receive(:bindings_available?).and_return(true)
      registry.put(page)
    end

    context "with a valid CSRF token" do
      before { set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}" }

      it "evaluates source in the frame's binding" do
        console_post(eval_path, {"csrfToken" => csrf_token, "index" => 0, "source" => "1 + 1"})

        expect(last_response.status).to eq(200)
        expect(last_response.headers["content-type"]).to eq("application/json; charset=utf-8")
        expect(json_body).to eq(
          "id" => page.id,
          "index" => 0,
          "source" => "1 + 1",
          "output" => "2",
          "error" => false
        )
      end

      it "returns the frame's variables" do
        console_post(variables_path, {"csrfToken" => csrf_token, "index" => 0})

        expect(last_response.status).to eq(200)
        expect(json_body).to eq(
          "id" => page.id,
          "index" => 0,
          "locals" => [["id", "String", '"247"']],
          "ivars" => [["@repo", "BookRepo", "#<BookRepo>"]]
        )
      end

      it "reports 404 for a frame that is not on the page" do
        console_post(variables_path, {"csrfToken" => csrf_token, "index" => 99})

        expect(last_response.status).to eq(404)
        expect(json_body["error"]).to eq("Unknown frame")
      end

      it "reports 410 for an unknown id, such as one from before a reload" do
        console_post(
          "/_hanami/webconsole/deadbeef/eval",
          {"csrfToken" => csrf_token, "index" => 0, "source" => "1 + 1"}
        )

        expect(last_response.status).to eq(410)
        expect(json_body).to include("error" => "Session expired", "action" => "refresh")
        expect(json_body["explanation"]).to match(/reloaded/i)
      end

      it "rejects a GET" do
        get eval_path

        expect(last_response.status).to eq(405)
      end

      it "rejects a non-JSON content type" do
        post eval_path, "csrfToken=#{csrf_token}", "CONTENT_TYPE" => "application/x-www-form-urlencoded"

        expect(last_response.status).to eq(406)
      end

      it "rejects a malformed body" do
        post eval_path, "{not json", "CONTENT_TYPE" => "application/json"

        expect(last_response.status).to eq(400)
      end

      describe "running the fix" do
        let(:run_path) { "/_hanami/webconsole/#{page.id}/run" }

        let(:runs) { [] }

        # Gives the page a diagnostic with a fix that calls the action when it runs.
        def stub_runnable_fix(action)
          diagnostic = Class.new {
            define_method(:fix) { {name: "Generate action", text: "Generate it."} }
            define_method(:run_fix) { action.call }
          }.new

          allow(page).to receive(:diagnostic).and_return(Hanami::Diagnostics::Wrapper.new(diagnostic))
        end

        before do
          stub_runnable_fix(-> {
            runs << :ran
            "Created app/actions/books/show.rb"
          })
        end

        it "runs the fix and returns its output" do
          console_post(run_path, {"csrfToken" => csrf_token})

          expect(last_response.status).to eq(200)
          expect(json_body).to eq(
            "id" => page.id,
            "name" => "Generate action",
            "ok" => true,
            "output" => "Created app/actions/books/show.rb"
          )
          expect(runs).to eq([:ran])
        end

        it "reports a fix that raises as failed" do
          stub_runnable_fix(-> { raise "permission denied" })

          console_post(run_path, {"csrfToken" => csrf_token})

          expect(last_response.status).to eq(200)
          expect(json_body).to include("ok" => false, "output" => "RuntimeError: permission denied")
        end

        it "reports 404 when the page has no fix that can run" do
          allow(page).to receive(:diagnostic).and_return(nil)

          console_post(run_path, {"csrfToken" => csrf_token})

          expect(last_response.status).to eq(404)
          expect(json_body["error"]).to eq("No fix to run")
        end

        it "reports 409 at once when another fix is running" do
          described_class::RUN_LOCK.lock

          begin
            console_post(run_path, {"csrfToken" => csrf_token})
          ensure
            described_class::RUN_LOCK.unlock
          end

          expect(last_response.status).to eq(409)
          expect(json_body["explanation"]).to match(/another fix is still running/i)
          expect(runs).to be_empty
        end

        it "requires a valid CSRF token" do
          console_post(run_path, {"csrfToken" => "some-other-token"})

          expect(last_response.status).to eq(403)
          expect(runs).to be_empty
        end
      end
    end

    describe "CSRF" do
      it "rejects a request with no cookie" do
        console_post(eval_path, {"csrfToken" => csrf_token, "index" => 0, "source" => "1 + 1"})

        expect(last_response.status).to eq(403)
        expect(json_body["error"]).to eq("Invalid CSRF token")
      end

      it "rejects a request whose body token does not match the cookie" do
        set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}"

        console_post(eval_path, {"csrfToken" => "some-other-token", "index" => 0, "source" => "1"})

        expect(last_response.status).to eq(403)
      end

      it "rejects a request with no token in the body" do
        set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}"

        console_post(eval_path, {"index" => 0, "source" => "1"})

        expect(last_response.status).to eq(403)
      end

      it "checks CSRF before looking the id up, so ids cannot be probed" do
        console_post("/_hanami/webconsole/deadbeef/eval", {"index" => 0, "source" => "1"})

        expect(last_response.status).to eq(403)
      end
    end

    it "leaves unrecognised console paths to the app" do
      get "/_hanami/webconsole/#{page.id}/something-else"

      expect(last_response.body).to eq("from the app")
    end
  end

  describe "the happy path" do
    it "returns the app's response unchanged" do
      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("from the app")
      expect(last_response.headers["content-security-policy"]).to be_nil
      expect(Hanami::Webconsole::ErrorPage).not_to have_received(:new)
    end
  end
end
