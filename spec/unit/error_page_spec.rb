# frozen_string_literal: true

require "did_you_mean"
require "hanami/webconsole/error_page"

RSpec.describe Hanami::Webconsole::ErrorPage do
  subject(:page) do
    described_class.new(exception:, env:, config:, id: "1-abc", generation: 1)
  end

  let(:exception) { RuntimeError.new("boom") }
  let(:env) { {"REQUEST_METHOD" => "GET", "PATH_INFO" => "/books/247"} }

  let(:render_error_responses) { Hash.new(:internal_server_error) }
  let(:logger_config) { double("logger config", filters: ["password"]) }
  let(:config) do
    double(
      "config",
      render_error_responses:,
      root: "/app",
      logger: logger_config
    )
  end

  describe "#id" do
    it "is the given id" do
      expect(page.id).to eq("1-abc")
    end

    it "defaults to a generation-stamped random id" do
      page = described_class.new(exception:, env:, config:, generation: 7)

      expect(page.id).to match(/\A7-[0-9a-f]{16}\z/)
      expect(page.generation).to eq(7)
    end

    it "defaults the generation to the current one" do
      allow(Hanami::Webconsole).to receive(:generation).and_return(42)

      page = described_class.new(exception:, env:, config:)

      expect(page.generation).to eq(42)
      expect(page.id).to start_with("42-")
    end
  end

  describe "#exception_class" do
    it "is the exception class name" do
      expect(page.exception_class).to eq("RuntimeError")
    end

    it "falls back to the class' string form for anonymous classes" do
      anonymous = Class.new(StandardError).new("boom")
      page = described_class.new(exception: anonymous, env:, config:)

      expect(page.exception_class).to start_with("#<Class:")
    end
  end

  describe "#message" do
    it "is the exception message" do
      expect(page.message).to eq("boom")
    end

    it "degrades when the message raises" do
      broken = RuntimeError.new("boom")
      allow(broken).to receive(:message).and_raise(NotImplementedError)

      page = described_class.new(exception: broken, env:, config:)

      expect(page.message).to eq("")
    end
  end

  describe "#detailed_extras" do
    it "returns the did_you_mean suggestion for a real typo" do
      stub_const("SpecBook", Class.new { def title = "Ruby" })

      exception = begin
        SpecBook.new.titel
      rescue NoMethodError => exception
        exception
      end

      page = described_class.new(exception:, env:, config:)

      expect(page.message).to include("titel")
      expect(page.detailed_extras).to include(a_string_matching(/Did you mean\?\s+title/))
      expect(page.detailed_extras).not_to include(a_string_including(page.message))
    end

    it "keeps the error_highlight caret lines, aligned" do
      exception = RuntimeError.new("undefined method 'foo' for nil")
      allow(exception).to receive(:detailed_message).with(highlight: false).and_return(
        "undefined method 'foo' for nil (RuntimeError)\n\n  x.foo.bar\n   ^^^^"
      )

      page = described_class.new(exception:, env:, config:)

      expect(page.detailed_extras).to eq(["  x.foo.bar", "   ^^^^"])
    end

    it "is empty when detailed_message adds nothing" do
      expect(page.detailed_extras).to eq([])
    end

    it "is empty when the exception does not respond to detailed_message" do
      exception = Class.new {
        def message
          "boom"
        end
      }.new

      page = described_class.new(exception:, env:, config:)

      expect(page.detailed_extras).to eq([])
    end

    it "is empty when detailed_message raises" do
      exception = RuntimeError.new("boom")
      allow(exception).to receive(:detailed_message).and_raise(SystemStackError)

      page = described_class.new(exception:, env:, config:)

      expect(page.detailed_extras).to eq([])
    end

    it "is empty when detailed_message is overridden with an incompatible signature" do
      klass = Class.new(StandardError) do
        def detailed_message
          "overridden"
        end
      end

      page = described_class.new(exception: klass.new("boom"), env:, config:)

      expect(page.detailed_extras).to eq([])
    end

    it "is empty when detailed_message does not return a string" do
      exception = RuntimeError.new("boom")
      allow(exception).to receive(:detailed_message).with(highlight: false).and_return(nil)

      page = described_class.new(exception:, env:, config:)

      expect(page.detailed_extras).to eq([])
    end
  end

  describe "#status" do
    it "resolves the symbol from config.render_error_responses" do
      render_error_responses["RuntimeError"] = :not_found

      expect(page.status).to eq(404)
    end

    it "defaults to 500 via the config default" do
      expect(page.status).to eq(500)
    end

    it "defaults to 500 when the config knows nothing of render_error_responses" do
      page = described_class.new(exception:, env:, config: double("config"))

      expect(page.status).to eq(500)
    end

    it "defaults to 500 for an unrecognised status symbol" do
      render_error_responses["RuntimeError"] = :not_a_status

      expect(page.status).to eq(500)
    end
  end

  describe "diagnostics", :isolate_diagnostics do
    let(:diagnostic_class) {
      Class.new do
        def initialize(exception, context)
          @exception = exception
          @context = context
        end

        def fix = "Fix #{@exception.message} in #{@context.slice}"
      end
    }

    let(:slice) { "Main::Slice" }

    subject(:page) { described_class.new(exception:, env:, config:, slice:) }

    describe "#diagnostic" do
      it "is nil when no diagnostic is registered" do
        expect(page.diagnostic).to be_nil
      end

      it "reads the registered diagnostic, built with the exception and the slice" do
        Hanami::Diagnostics::Registry.register("RuntimeError", diagnostic_class)

        expect(page.diagnostic.fix.text).to eq("Fix boom in Main::Slice")
      end

      it "is built once" do
        Hanami::Diagnostics::Registry.register("RuntimeError", diagnostic_class)

        expect(page.diagnostic).to be(page.diagnostic)
      end
    end

    describe "#actionable?" do
      it "is true when the diagnostic has a fix" do
        Hanami::Diagnostics::Registry.register("RuntimeError", diagnostic_class)

        expect(page.actionable?).to be(true)
      end

      it "is false when the diagnostic has no fix" do
        Hanami::Diagnostics::Registry.register("RuntimeError", Class.new {
          def initialize(*) = nil

          def explanation = "Why."
        })

        expect(page.actionable?).to be(false)
      end
    end
  end

  describe "#causes" do
    it "is empty without a cause" do
      expect(page.causes).to eq([])
    end

    it "walks the cause chain, outermost cause last" do
      exception = begin
        begin
          begin
            raise ArgumentError, "innermost"
          rescue ArgumentError
            raise TypeError, "middle"
          end
        rescue TypeError
          raise "outer"
        end
      rescue RuntimeError => exception
        exception
      end

      page = described_class.new(exception:, env:, config:)

      expect(page.causes).to eq(["TypeError", "ArgumentError"])
    end
  end

  describe "#frames" do
    it "delegates to the backtrace" do
      app_frame = instance_double(Hanami::Webconsole::Frame)
      gem_frame = instance_double(Hanami::Webconsole::Frame)
      backtrace = instance_double(Hanami::Webconsole::Backtrace, frames: [app_frame, gem_frame], app_frames: [app_frame])
      allow(Hanami::Webconsole::Backtrace).to receive(:new).and_return(backtrace)

      expect(page.frames).to eq([app_frame, gem_frame])
      expect(page.app_frames).to eq([app_frame])
    end

    it "degrades to an empty list when the backtrace raises" do
      allow(Hanami::Webconsole::Backtrace).to receive(:new).and_raise(NoMethodError)

      expect(page.frames).to eq([])
    end
  end

  describe "#request" do
    it "reads the request from the env, filtering the params the logger filters" do
      env = Rack::MockRequest.env_for("/books/247?id=247&password=secret")
      page = described_class.new(exception:, env:, config:)

      expect(page.request).to have_attributes(method_name: "GET", path: "/books/247")
      expect(page.request.params).to eq("id" => '"247"', "password" => "[FILTERED]")
    end
  end

  describe "#root" do
    it "comes from the config" do
      expect(page.root).to eq("/app")
    end

    it "falls back to the working directory" do
      page = described_class.new(exception:, env:, config: double("config"))

      expect(page.root).to eq(Dir.pwd)
    end
  end
end
