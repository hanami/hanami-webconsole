# frozen_string_literal: true

require "hanami/webconsole/request_context"

RSpec.describe Hanami::Webconsole::RequestContext do
  subject(:context) { described_class.new(env:, filters:) }

  let(:filters) { Hanami::Webconsole::Filters.new(["password", "cookie"]) }
  let(:env) { Rack::MockRequest.env_for("/books/247", env_overrides) }
  let(:env_overrides) { {} }

  describe "the basics" do
    let(:env_overrides) do
      {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_ACCEPT" => "text/html,application/xhtml+xml;q=0.9"
      }
    end

    it "exposes the request line" do
      expect(context.method_name).to eq("POST")
      expect(context.path).to eq("/books/247")
      expect(context.ip).to eq("127.0.0.1")
      expect(context.format).to eq("text/html")
    end
  end

  describe "#format" do
    it "falls back to the content type when Accept is unhelpful" do
      env = Rack::MockRequest.env_for(
        "/", "HTTP_ACCEPT" => "*/*", "CONTENT_TYPE" => "application/json; charset=utf-8"
      )

      expect(described_class.new(env:, filters:).format).to eq("application/json")
    end

    it "is empty when nothing says" do
      env = Rack::MockRequest.env_for("/")
      env.delete("HTTP_ACCEPT")
      env.delete("CONTENT_TYPE")

      expect(described_class.new(env:, filters:).format).to eq("")
    end
  end

  describe "#params" do
    let(:env) do
      Rack::MockRequest.env_for(
        "/books/247?q=ruby&password=secret",
        method: "POST",
        params: {"title" => "Hanami", "user" => {"password" => "hunter2", "email" => "a@b.com"}}
      )
    end

    it "filters and inspects" do
      expect(context.params["q"]).to eq('"ruby"')
      expect(context.params["title"]).to eq('"Hanami"')
      # The exact object, which is how the page tells a filtered value apart (see Rendering::HTML).
      expect(context.params["password"]).to equal(Hanami::Webconsole::Filters::FILTERED)
    end

    it "filters nested params" do
      expect(context.params["user"]).to eq('{"password" => "[FILTERED]", "email" => "a@b.com"}')
    end

    it "returns an empty hash when params cannot be parsed" do
      allow_any_instance_of(Rack::Request).to receive(:params).and_raise(RuntimeError)

      expect(context.params).to eq({})
    end
  end

  describe "#session" do
    it "is empty when there is no session" do
      expect(context.session).to eq({})
    end

    it "filters and inspects the session" do
      env["rack.session"] = {"user_id" => 1, "password" => "secret", :sym => :value}

      expect(context.session).to eq(
        {"user_id" => "1", "password" => "[FILTERED]", "sym" => ":value"}
      )
    end

    it "reads a session object that only responds to #to_hash" do
      store = Class.new do
        def to_hash
          {"user_id" => 7}
        end
      end.new
      env["rack.session"] = store

      expect(context.session).to eq({"user_id" => "7"})
    end

    it "is empty when the session raises on access" do
      store = Class.new do
        def to_hash
          raise "session store is not loaded"
        end
      end.new
      env["rack.session"] = store

      expect(context.session).to eq({})
    end

    it "is empty when the session is not hash-like" do
      env["rack.session"] = "nonsense"

      expect(context.session).to eq({})
    end
  end

  describe "#cookies" do
    let(:env_overrides) { {"HTTP_COOKIE" => "theme=dark; _session=abc123"} }

    it "returns cookies as plain strings" do
      expect(context.cookies["theme"]).to eq("dark")
    end

    it "filters cookies by name" do
      filters = Hanami::Webconsole::Filters.new(["_session"])
      cookies = described_class.new(env:, filters:).cookies

      expect(cookies).to eq({"theme" => "dark", "_session" => "[FILTERED]"})
    end

    it "is empty when cookies cannot be read" do
      allow_any_instance_of(Rack::Request).to receive(:cookies).and_raise(RuntimeError)

      expect(context.cookies).to eq({})
    end
  end

  describe "#headers" do
    let(:env_overrides) do
      {
        "HTTP_ACCEPT_LANGUAGE" => "en-GB,en;q=0.9",
        "HTTP_X_FORWARDED_FOR" => "10.0.0.1",
        "HTTP_HOST" => "example.com",
        "HTTP_COOKIE" => "_session=abc123",
        "CONTENT_TYPE" => "application/json",
        "CONTENT_LENGTH" => "17",
        "rack.url_scheme" => "https",
        "SERVER_NAME" => "example.com"
      }
    end

    it "de-prefixes and title-cases HTTP_ variables" do
      expect(context.headers["Accept-Language"]).to eq("en-GB,en;q=0.9")
      expect(context.headers["X-Forwarded-For"]).to eq("10.0.0.1")
      expect(context.headers["Host"]).to eq("example.com")
    end

    it "includes the content headers" do
      expect(context.headers["Content-Type"]).to eq("application/json")
      expect(context.headers["Content-Length"]).to eq("17")
    end

    it "excludes non-header env variables" do
      expect(context.headers.keys).not_to include("SERVER_NAME", "rack.url_scheme", "Rack.url")
    end

    it "filters headers, so Cookie is redacted when 'cookie' is a filter key" do
      expect(context.headers["Cookie"]).to eq("[FILTERED]")
    end

    it "does not filter headers when the key is not configured" do
      plain = described_class.new(env:, filters: Hanami::Webconsole::Filters.new)

      expect(plain.headers["Cookie"]).to eq("_session=abc123")
    end

    it "sorts headers by name" do
      expect(context.headers.keys).to eq(context.headers.keys.sort)
    end

    it "stringifies odd values" do
      env["HTTP_WEIRD"] = 42

      expect(context.headers["Weird"]).to eq("42")
    end

    it "scrubs invalid bytes" do
      env["HTTP_X_BAD"] = "bad \xff byte"

      expect(context.headers["X-Bad"]).to be_valid_encoding
    end
  end

  describe "degrading" do
    it "works against an empty env" do
      context = described_class.new(env: {}, filters:)

      expect(context.method_name).to eq("")
      expect(context.path).to eq("")
      expect(context.format).to eq("")
      expect(context.ip).to eq("")
      expect(context.params).to eq({})
      expect(context.session).to eq({})
      expect(context.cookies).to eq({})
      expect(context.headers).to eq({})
    end

    it "works when the env is not a hash at all" do
      context = described_class.new(env: nil, filters: nil)

      expect { context.headers }.not_to raise_error
      expect(context.headers).to eq({})
      expect(context.params).to eq({})
    end

    it "returns strings everywhere" do
      env["rack.session"] = {"a" => Object.new}

      [context.method_name, context.path, context.format, context.ip]
        .each { |value| expect(value).to be_a(String) }

      [context.params, context.session, context.cookies, context.headers].each do |hash|
        hash.each do |key, value|
          expect(key).to be_a(String)
          expect(value).to be_a(String)
        end
      end
    end
  end
end
