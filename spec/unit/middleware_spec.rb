# frozen_string_literal: true

require "rack/mock"

RSpec.describe Hanami::Webconsole::Middleware do
  subject(:middleware) { described_class.new(app, config) }

  let(:app) { ->(_env) { raise "boom" } }
  let(:config) { double("Config", root: SPEC_ROOT, render_error_responses: Hash.new(:internal_server_error)) }

  def call(headers)
    middleware.call(Rack::MockRequest.env_for("/", {"HTTP_ACCEPT" => "text/html"}.merge(headers)))
  end

  describe "IP allowlist" do
    it "shows the error page to a loopback peer" do
      status, = call("REMOTE_ADDR" => "127.0.0.1")

      expect(status).to eq 500
    end

    it "shows the error page to an IPv6 loopback peer with a zone id" do
      status, = call("REMOTE_ADDR" => "::1%lo0")

      expect(status).to eq 500
    end

    it "shows the error page to a loopback peer that sends a forwarding header" do
      status, = call("REMOTE_ADDR" => "127.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.10")

      expect(status).to eq 500
    end

    it "denies a non-loopback peer" do
      expect { call("REMOTE_ADDR" => "192.168.1.50") }.to raise_error(RuntimeError, "boom")
    end

    {
      "HTTP_X_FORWARDED_FOR" => "127.0.0.1",
      "HTTP_CLIENT_IP" => "127.0.0.1",
      "HTTP_FORWARDED" => "for=127.0.0.1"
    }.each do |header, value|
      it "denies a private-network peer that spoofs loopback via #{header}" do
        expect { call("REMOTE_ADDR" => "192.168.1.50", header => value) }
          .to raise_error(RuntimeError, "boom")
      end
    end

    it "denies a request with a blank REMOTE_ADDR" do
      expect { call("REMOTE_ADDR" => "") }.to raise_error(RuntimeError, "boom")
    end

    it "denies an unparseable REMOTE_ADDR rather than raising" do
      expect { call("REMOTE_ADDR" => "not-an-ip") }.to raise_error(RuntimeError, "boom")
    end
  end
end
