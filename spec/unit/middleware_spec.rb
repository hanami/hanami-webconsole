# frozen_string_literal: true

require "json"

# The middleware collaborates with objects owned by other workstreams (see CONTRACTS.md). They are
# stubbed here so this spec runs standalone, and so a change in their internals cannot quietly
# change what the middleware is asserted to do.
RSpec.describe Hanami::Webconsole::Middleware, type: :rack do
  subject(:middleware) { described_class.new(inner_app, config) }

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

  let(:error_responses) { Hash.new(:internal_server_error) }
  let(:config) { double("Config", render_error_responses: error_responses, root: "/app") }

  # --- collaborators ---------------------------------------------------------------------------

  let(:variable_struct) { Struct.new(:name, :class_name, :value, keyword_init: true) }

  let(:frame) do
    double(
      "Frame",
      display_path: "app/actions/books/show.rb",
      lineno: 12,
      label: "Books::Show#handle",
      kind: :app,
      binding: Object.new,
      receiver_inspect: "#<Books::Show>",
      locals: [variable_struct.new(name: "id", class_name: "String", value: '"247"')],
      instance_vars: [variable_struct.new(name: "@repo", class_name: "BookRepo", value: "#<BookRepo>")]
    )
  end

  let(:page_id) { "0-abcdef0123456789" }

  let(:error_page) do
    double(
      "ErrorPage",
      id: page_id,
      exception_class: "RuntimeError",
      message: "boom",
      detailed_extras: [],
      causes: [],
      frames: [frame],
      to_text: "# RuntimeError\n\nboom\n"
    )
  end

  # Records the keyword arguments the middleware builds a page with.
  let(:page_args) { [] }

  let(:error_page_class) do
    page = error_page
    args = page_args

    Class.new do
      define_singleton_method(:new) do |**kwargs|
        args << kwargs
        page
      end
    end
  end

  # Shared with the spec so console endpoints can be exercised without first rendering a page.
  let(:registry_store) { {} }

  let(:registry_class) do
    store = registry_store

    Class.new do
      define_method(:initialize) { |max: 16| @max = max }
      define_method(:put) do |page|
        store[page.id] = page
        page.id
      end
      define_method(:fetch) { |id| store[id] }
    end
  end

  let(:renderer_module) do
    Module.new do
      def self.render_html(page, nonce:, csrf_token:)
        "<html><body data-webconsole-nonce=\"#{nonce}\" data-webconsole-csrf=\"#{csrf_token}\">" \
          "#{page.exception_class}</body></html>"
      end

      def self.render_text(page)
        page.to_text
      end

      def self.render_json(page)
        JSON.generate("error" => page.exception_class, "message" => page.message)
      end
    end
  end

  let(:session_class) do
    Class.new do
      def initialize(frame_binding)
        @frame_binding = frame_binding
      end

      def eval(source)
        ["=> #{source}", false]
      end
    end
  end

  before do
    stub_const("Hanami::Webconsole::ErrorPage", error_page_class)
    stub_const("Hanami::Webconsole::Registry", registry_class)
    stub_const("Hanami::Webconsole::Renderer", renderer_module)
    stub_const("Hanami::Webconsole::Repl::Session", session_class)
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

          expect(page_args).to be_empty
          expect(registry_store).to be_empty
        end
      end

      it "does not serve the console endpoints" do
        registry_store[page_id] = error_page
        set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}"

        console_post(
          "/_hanami/webconsole/#{page_id}/eval",
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

    it "renders HTML with the configured status" do
      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(500)
      expect(last_response.headers["content-type"]).to eq("text/html; charset=utf-8")
      expect(last_response.body).to include("RuntimeError")
    end

    it "builds the page with a generation-stamped id and stores it in the registry" do
      get "/", {}, "HTTP_ACCEPT" => "text/html"

      args = page_args.fetch(0)
      expect(args[:exception]).to be(raised)
      expect(args[:config]).to be(config)
      expect(args[:env]).to include("PATH_INFO" => "/")
      expect(args[:generation]).to eq(Hanami::Webconsole.generation)
      expect(args[:id]).to match(/\A#{Hanami::Webconsole.generation}-[0-9a-f]+\z/)

      expect(registry_store).to eq(page_id => error_page)
    end

    it "maps Hanami::Router::NotFoundError to 404, not 500" do
      stub_const("Hanami::Router::NotFoundError", Class.new(StandardError))
      error_responses["Hanami::Router::NotFoundError"] = :not_found

      allow(inner_app).to receive(:call).and_raise(Hanami::Router::NotFoundError.new("nope"))

      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(404)
    end

    it "falls back to 500 when the exception is not mapped to a status" do
      allow(config).to receive(:render_error_responses).and_return({})

      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(500)
    end

    it "rescues non-StandardError exceptions" do
      allow(inner_app).to receive(:call).and_raise(NotImplementedError.new("nope"))

      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(500)
      expect(page_args.size).to eq(1)
    end

    it "falls back to plain text when the page itself cannot be rendered" do
      allow(error_page_class).to receive(:new).and_raise(ArgumentError.new("bad contract"))

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
    end

    describe "the CSRF cookie" do
      it "is set, httponly and same-site strict, when not already present" do
        get "/", {}, "HTTP_ACCEPT" => "text/html"

        cookie = set_cookies.find { |value| value.start_with?("Hanami-Webconsole-CSRF-Token=") }

        expect(cookie).not_to be_nil
        expect(cookie).to match(/httponly/i)
        expect(cookie).to match(/samesite=strict/i)
        expect(cookie).to match(%r{path=/})
      end

      it "is not reset when the browser already has one" do
        set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}"

        get "/", {}, "HTTP_ACCEPT" => "text/html"

        expect(set_cookies).to be_empty
        expect(last_response.body).to include(%(data-webconsole-csrf="#{csrf_token}"))
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
        expect(last_response.body).to eq(error_page.to_text)
      end

      it "renders text for an XHR that would otherwise accept HTML" do
        get "/", {}, "HTTP_ACCEPT" => "text/html", "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest"

        expect(last_response.headers["content-type"]).to eq("text/plain; charset=utf-8")
        expect(last_response.body).to eq(error_page.to_text)
      end

      it "renders HTML for a browser Accept header" do
        get "/", {}, "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

        expect(last_response.headers["content-type"]).to eq("text/html; charset=utf-8")
      end
    end
  end

  describe "console endpoints" do
    let(:eval_path) { "/_hanami/webconsole/#{page_id}/eval" }
    let(:variables_path) { "/_hanami/webconsole/#{page_id}/variables" }

    before do
      allow(Hanami::Webconsole).to receive(:bindings_available?).and_return(true)
      registry_store[page_id] = error_page
    end

    context "with a valid CSRF token" do
      before { set_cookie "Hanami-Webconsole-CSRF-Token=#{csrf_token}" }

      it "evaluates source in the frame's binding" do
        console_post(eval_path, {"csrfToken" => csrf_token, "index" => 0, "source" => "1 + 1"})

        expect(last_response.status).to eq(200)
        expect(last_response.headers["content-type"]).to eq("application/json; charset=utf-8")
        expect(json_body).to eq(
          "id" => page_id,
          "index" => 0,
          "source" => "1 + 1",
          "output" => "=> 1 + 1",
          "error" => false
        )
      end

      it "returns the frame's variables" do
        console_post(variables_path, {"csrfToken" => csrf_token, "index" => 0})

        expect(last_response.status).to eq(200)
        expect(json_body).to eq(
          "id" => page_id,
          "index" => 0,
          "replAvailable" => true,
          "receiver" => "#<Books::Show>",
          "locals" => [{"name" => "id", "className" => "String", "value" => '"247"'}],
          "instanceVariables" => [
            {"name" => "@repo", "className" => "BookRepo", "value" => "#<BookRepo>"}
          ]
        )
      end

      it "reports 404 for a frame that is not on the page" do
        console_post(variables_path, {"csrfToken" => csrf_token, "index" => 99})

        expect(last_response.status).to eq(404)
        expect(json_body["error"]).to eq("Unknown frame")
      end

      it "reports 410 for an unknown or generation-expired id" do
        console_post(
          "/_hanami/webconsole/999-deadbeef/eval",
          {"csrfToken" => csrf_token, "index" => 0, "source" => "1 + 1"}
        )

        expect(last_response.status).to eq(410)
        expect(json_body).to include("error" => "Session expired", "action" => "refresh")
        expect(json_body["explanation"]).to match(/code reload/i)
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
        console_post("/_hanami/webconsole/999-deadbeef/eval", {"index" => 0, "source" => "1"})

        expect(last_response.status).to eq(403)
      end
    end

    it "leaves unrecognised console paths to the app" do
      get "/_hanami/webconsole/#{page_id}/something-else"

      expect(last_response.body).to eq("from the app")
    end
  end

  describe "the happy path" do
    it "returns the app's response unchanged" do
      get "/", {}, "HTTP_ACCEPT" => "text/html"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("from the app")
      expect(last_response.headers["content-security-policy"]).to be_nil
      expect(page_args).to be_empty
    end
  end
end
