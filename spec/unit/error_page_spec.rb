# frozen_string_literal: true

require "did_you_mean"
require "hanami/webconsole/error_page"

RSpec.describe Hanami::Webconsole::ErrorPage do
  subject(:page) do
    described_class.new(exception: exception, env: env, config: config, id: "1-abc", generation: 1)
  end

  let(:exception) { RuntimeError.new("boom") }
  let(:env) { {"REQUEST_METHOD" => "GET", "PATH_INFO" => "/books/247"} }

  let(:render_error_responses) { Hash.new(:internal_server_error) }
  let(:logger_config) { double("logger config", filters: ["password"]) }
  let(:config) do
    double(
      "config",
      render_error_responses: render_error_responses,
      root: "/app",
      logger: logger_config
    )
  end

  # Owned by other workstreams; stubbed so this spec stands alone. See CONTRACTS.md.
  let(:excerpt_class) do
    Struct.new(:path, :first_lineno, :lines, :highlight_lineno, keyword_init: true)
  end

  let(:app_frame) do
    frame_double(
      display_path: "app/actions/books/show.rb",
      lineno: 16,
      label: "Show#handle",
      app: true,
      source: excerpt_class.new(
        path: "/app/app/actions/books/show.rb",
        first_lineno: 14,
        lines: ["  def handle(request, response)", "    book_repo = deps[:book_repo]", "    result = book_repo.find_with_reviews(...)"],
        highlight_lineno: 16
      )
    )
  end

  let(:gem_frame) do
    frame_double(
      display_path: "rack-3.1.8/lib/rack/method_override.rb",
      lineno: 24,
      label: "Rack::MethodOverride#call",
      app: false
    )
  end

  let(:frames) { [app_frame, gem_frame] }
  let(:app_frames) { [app_frame] }

  def frame_double(display_path:, lineno:, label:, app:, source: nil)
    double(
      "Frame",
      display_path: display_path,
      lineno: lineno,
      label: label,
      app?: app,
      source: source
    )
  end

  before do
    stub_const("Hanami::Webconsole::Filters", class_double_returning(double("Filters")))
    stub_const("Hanami::Webconsole::RequestContext", class_double_returning(request_context))
    stub_const("Hanami::Webconsole::Backtrace", class_double_returning(backtrace))
  end

  let(:request_context) { double("RequestContext", method_name: "GET", path: "/books/247") }
  let(:backtrace) { double("Backtrace", frames: frames, app_frames: app_frames) }

  def class_double_returning(instance)
    klass = double("class")
    allow(klass).to receive(:new).and_return(instance)
    klass
  end

  describe "#id" do
    it "is the given id" do
      expect(page.id).to eq("1-abc")
    end

    it "defaults to a generation-stamped random id" do
      page = described_class.new(exception: exception, env: env, config: config, generation: 7)

      expect(page.id).to match(/\A7-[0-9a-f]{16}\z/)
      expect(page.generation).to eq(7)
    end

    it "defaults the generation to the current one" do
      allow(Hanami::Webconsole).to receive(:generation).and_return(42)

      page = described_class.new(exception: exception, env: env, config: config)

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
      page = described_class.new(exception: anonymous, env: env, config: config)

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

      page = described_class.new(exception: broken, env: env, config: config)

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

      page = described_class.new(exception: exception, env: env, config: config)

      expect(page.message).to include("titel")
      expect(page.detailed_extras).to include(a_string_matching(/Did you mean\?\s+title/))
      expect(page.detailed_extras).not_to include(a_string_including(page.message))
    end

    it "keeps the error_highlight caret lines, aligned" do
      exception = RuntimeError.new("undefined method 'foo' for nil")
      allow(exception).to receive(:detailed_message).with(highlight: false).and_return(
        "undefined method 'foo' for nil (RuntimeError)\n\n  x.foo.bar\n   ^^^^"
      )

      page = described_class.new(exception: exception, env: env, config: config)

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

      page = described_class.new(exception: exception, env: env, config: config)

      expect(page.detailed_extras).to eq([])
    end

    it "is empty when detailed_message raises" do
      exception = RuntimeError.new("boom")
      allow(exception).to receive(:detailed_message).and_raise(NoMemoryError)

      page = described_class.new(exception: exception, env: env, config: config)

      expect(page.detailed_extras).to eq([])
    end

    it "is empty when detailed_message is overridden with an incompatible signature" do
      klass = Class.new(StandardError) do
        def detailed_message
          "overridden"
        end
      end

      page = described_class.new(exception: klass.new("boom"), env: env, config: config)

      expect(page.detailed_extras).to eq([])
    end

    it "is empty when detailed_message does not return a string" do
      exception = RuntimeError.new("boom")
      allow(exception).to receive(:detailed_message).with(highlight: false).and_return(nil)

      page = described_class.new(exception: exception, env: env, config: config)

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
      page = described_class.new(exception: exception, env: env, config: double("config"))

      expect(page.status).to eq(500)
    end

    it "defaults to 500 for an unrecognised status symbol" do
      render_error_responses["RuntimeError"] = :not_a_status

      expect(page.status).to eq(500)
    end
  end

  describe "#severity" do
    after { Hanami::Webconsole::Presenters.reset! }

    it "is :crash for an unrecognised exception" do
      expect(page.severity).to eq(:crash)
    end

    it "is :actionable when a presenter matches" do
      Hanami::Webconsole::Presenters.register("RuntimeError", Hanami::Webconsole::Presenters::Base)

      expect(page.severity).to eq(:actionable)
    end

    it "is :not_found for a 404, even when a presenter matches" do
      render_error_responses["RuntimeError"] = :not_found
      Hanami::Webconsole::Presenters.register("RuntimeError", Hanami::Webconsole::Presenters::Base)

      expect(page.severity).to eq(:not_found)
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

      page = described_class.new(exception: exception, env: env, config: config)

      expect(page.causes).to eq(["TypeError", "ArgumentError"])
    end
  end

  describe "#presenter" do
    after { Hanami::Webconsole::Presenters.reset! }

    it "is nil when nothing is registered" do
      expect(page.presenter).to be_nil
    end

    it "is the registered presenter" do
      Hanami::Webconsole::Presenters.register("RuntimeError", Hanami::Webconsole::Presenters::Base)

      expect(page.presenter).to be_a(Hanami::Webconsole::Presenters::Base)
    end
  end

  describe "#frames" do
    it "delegates to the backtrace" do
      expect(page.frames).to eq(frames)
      expect(page.app_frames).to eq(app_frames)
    end

    it "degrades to an empty list when the backtrace raises" do
      allow(Hanami::Webconsole::Backtrace).to receive(:new).and_raise(NoMethodError)

      expect(page.frames).to eq([])
    end
  end

  describe "#root" do
    it "comes from the config" do
      expect(page.root).to eq("/app")
    end

    it "falls back to the working directory" do
      page = described_class.new(exception: exception, env: env, config: double("config"))

      expect(page.root).to eq(Dir.pwd)
    end
  end

  describe "#to_text" do
    let(:exception) do
      exception = NoMethodError.new("undefined method 'titel' for an instance of Foo")

      allow(exception).to receive(:detailed_message).with(highlight: false).and_return(
        "undefined method 'titel' for an instance of Foo (NoMethodError)\nDid you mean?  title"
      )

      exception
    end

    it "renders the error as Markdown" do
      expect(page.to_text).to eq(<<~TEXT)
        ## NoMethodError

        undefined method 'titel' for an instance of Foo

        - Request: GET /books/247
        - Status: 500

        Did you mean?  title

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

    it "lists the cause chain" do
      allow(exception).to receive(:cause).and_return(ArgumentError.new("root cause"))

      expect(page.to_text).to include("- Caused by: ArgumentError")
    end

    it "omits the source section when no source is available" do
      allow(app_frame).to receive(:source).and_return(nil)

      expect(page.to_text).not_to include("### Source")
    end

    it "omits the backtrace section when there are no frames" do
      allow(backtrace).to receive_messages(frames: [], app_frames: [])

      text = page.to_text

      expect(text).not_to include("### Backtrace")
      expect(text).to include("- Status: 500")
    end

    it "truncates long backtraces" do
      many = Array.new(30) { gem_frame }
      allow(backtrace).to receive_messages(frames: many, app_frames: [])

      text = page.to_text

      expect(text).to include("### Backtrace (0 application frames of 30)")
      expect(text).to include("  # … 5 more frames")
    end

    it "never raises, even when everything is broken" do
      allow(Hanami::Webconsole::Backtrace).to receive(:new).and_raise(NoMethodError)
      allow(Hanami::Webconsole::RequestContext).to receive(:new).and_raise(NoMethodError)

      expect(page.to_text).to include("## NoMethodError")
    end
  end
end
