# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::Resolution do
  # A resolution written the way a gem would write it: no dependency on hanami, nothing
  # included, just a name and something callable.
  def resolution(name, destructive: false, &block)
    Struct.new(:name, :destructive, :run) do
      def destructive? = !!destructive
      def call(context) = run.call(context)
    end.new(name, destructive, block)
  end

  def error_offering(*candidates)
    Class.new(StandardError) do
      define_method(:resolutions) { candidates }
    end.new("boom")
  end

  describe ".for" do
    it "reads resolutions off anything that offers them" do
      exception = error_offering(resolution("Run migrations"))

      found = described_class.for(exception)

      expect(found.length).to eq(1)
      expect(found.first.name).to eq("Run migrations")
      expect(found.first).to be_a(described_class)
    end

    it "is empty for an error that offers none" do
      expect(described_class.for(RuntimeError.new("plain"))).to eq([])
    end

    it "defaults destructive? to false when the resolution does not say" do
      minimal = Struct.new(:name) { def call(_context) = nil }.new("Minimal")

      expect(described_class.for(error_offering(minimal)).first).not_to be_destructive
    end

    it "carries destructive? through when it does" do
      exception = error_offering(resolution("Roll back", destructive: true))

      expect(described_class.for(exception).first).to be_destructive
    end

    it "skips candidates that do not fit the contract" do
      exception = error_offering(resolution("Good"), Object.new, nil, "a string")

      expect(described_class.for(exception).map(&:name)).to eq(["Good"])
    end

    it "skips a resolution with a blank name, since the page has no way to label it" do
      exception = error_offering(resolution(""), resolution("Named"))

      expect(described_class.for(exception).map(&:name)).to eq(["Named"])
    end

    # `#resolutions` is arbitrary user code, and it runs while rendering a page that exists
    # because something already went wrong.
    it "is empty when the error's own #resolutions raises" do
      exception = Class.new(StandardError) do
        def resolutions = raise(NotImplementedError, "nope")
      end.new("boom")

      expect(described_class.for(exception)).to eq([])
    end

    it "is empty when #resolutions returns something that is not a collection" do
      exception = Class.new(StandardError) do
        def resolutions = :not_a_list
      end.new("boom")

      expect(described_class.for(exception)).to eq([])
    end
  end

  describe "guidance" do
    # A resolution with no #call: nothing to run, nothing to secure, still helpful.
    def guidance(name, **content)
      Struct.new(:name, :command, :snippet, :items, :note, keyword_init: true)
        .new(name: name, **content)
    end

    it "accepts a resolution with no #call" do
      found = described_class.for(error_offering(guidance("Add the route", snippet: "get '/x'")))

      expect(found.length).to eq(1)
      expect(found.first).not_to be_executable
      expect(found.first.snippet).to eq("get '/x'")
    end

    it "reads every content method" do
      found = described_class.for(
        error_offering(
          guidance("Fix it", command: "hanami db migrate", items: %w[a.rb b.rb], note: "careful")
        )
      ).first

      expect(found.command).to eq("hanami db migrate")
      expect(found.items).to eq(%w[a.rb b.rb])
      expect(found.note).to eq("careful")
      expect(found).to be_guidance
    end

    it "skips a resolution that can neither run nor say anything" do
      expect(described_class.for(error_offering(guidance("Empty")))).to eq([])
    end

    it "treats a runnable resolution with a command as one fix offered two ways" do
      both = Struct.new(:name, :command) do
        def call(_context) = "ran"
      end.new("Run migrations", "hanami db migrate")

      found = described_class.for(error_offering(both)).first

      expect(found).to be_executable
      expect(found.command).to eq("hanami db migrate")
    end

    it "ignores content that raises when read" do
      hostile = Struct.new(:name) do
        def call(_context) = nil
        def note = raise(NotImplementedError)
      end.new("Fine")

      expect(described_class.for(error_offering(hostile)).first.note).to be_nil
    end

    it "caps runaway content and lists" do
      huge = Struct.new(:name, :note, :items, keyword_init: true)
        .new(name: "Big", note: "x" * 50_000, items: Array.new(500, "item.rb"))
      # No #call, so it is guidance — still has to be bounded.
      found = described_class.for(error_offering(huge)).first

      expect(found.note.length).to eq(described_class::MAX_TEXT)
      expect(found.items.length).to eq(described_class::MAX_ITEMS)
    end

    it "refuses to run a guidance-only resolution" do
      found = described_class.for(error_offering(guidance("Read this", note: "hello"))).first

      result = found.call(described_class::Context.new(app: nil, slice: nil, request: nil))

      expect(result).not_to be_ok
    end
  end

  describe "#call" do
    let(:context) { described_class::Context.new(app: :the_app, slice: nil, request: nil) }

    it "runs the resolution and reports success" do
      ran_with = nil
      found = described_class.for(error_offering(resolution("Seed") { |c| ran_with = c; "done" }))

      result = found.first.call(context)

      expect(result).to be_ok
      expect(result.output).to eq('"done"')
      expect(ran_with).to be(context)
    end

    it "reports a raised failure instead of raising" do
      found = described_class.for(
        error_offering(resolution("Seed") { raise IOError, "the disk caught fire" })
      )

      result = found.first.call(context)

      expect(result).not_to be_ok
      expect(result.output).to eq("IOError: the disk caught fire")
    end

    it "survives a resolution that raises outside StandardError" do
      found = described_class.for(error_offering(resolution("Seed") { raise NotImplementedError }))

      expect(found.first.call(context)).not_to be_ok
    end

    it "reports an empty output for a resolution that returns nothing useful" do
      found = described_class.for(error_offering(resolution("Seed") { nil }))

      expect(found.first.call(context).output).to eq("")
    end

    it "truncates an enormous return value rather than embedding it whole" do
      found = described_class.for(error_offering(resolution("Seed") { "x" * 100_000 }))

      expect(found.first.call(context).output.length).to be <= 4_000
    end
  end
end
