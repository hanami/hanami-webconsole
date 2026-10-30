# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::Diagnostics do
  # The registry is global. Save and restore it, including the diagnostics the gem ships.
  around do |example|
    saved = described_class.registry.dup

    begin
      example.run
    ensure
      described_class.registry.replace(saved)
    end
  end

  let(:context) { described_class::Context.new(slice: "Main::Slice") }

  # A diagnostic whose fix names itself, so specs can tell which one was found.
  def diagnostic(label, applies: true)
    Class.new do
      define_method(:initialize) { |exception, context| @exception, @context = exception, context }
      define_method(:applies?) { applies.respond_to?(:call) ? applies.call : applies }
      define_method(:fix) { "#{label}: #{@exception.message}" }
    end
  end

  def found(exception)
    described_class.for(exception, context)&.fix&.text
  end

  describe ".register" do
    it "registers by class name, without loading the class" do
      described_class.register("Some::Gem::NotLoadedError", diagnostic("not loaded"))

      expect(described_class.registry).to include("Some::Gem::NotLoadedError")
    end
  end

  describe ".for" do
    it "is nil when nothing matches" do
      expect(found(RuntimeError.new("boom"))).to be_nil
    end

    it "builds the diagnostic with the exception and the context" do
      described_class.register("RuntimeError", Class.new {
        define_method(:initialize) { |exception, context| @text = "#{exception.message} in #{context.slice}" }
        define_method(:fix) { @text }
      })

      expect(found(RuntimeError.new("boom"))).to eq("boom in Main::Slice")
    end

    it "covers subclasses of a registered class" do
      described_class.register("StandardError", diagnostic("standard"))

      expect(found(ArgumentError.new("bad"))).to eq("standard: bad")
    end

    it "prefers the closest ancestor" do
      described_class.register("StandardError", diagnostic("standard"))
      described_class.register("ArgumentError", diagnostic("argument"))

      expect(found(ArgumentError.new("bad"))).to eq("argument: bad")
    end

    it "walks the cause chain, for an error that wraps another" do
      described_class.register("KeyError", diagnostic("key"))

      expect(found(wrapped(RuntimeError.new("outer"), KeyError.new("inner")))).to eq("key: inner")
    end

    it "prefers the outer error to its cause" do
      described_class.register("RuntimeError", diagnostic("runtime"))
      described_class.register("KeyError", diagnostic("key"))

      expect(found(wrapped(RuntimeError.new("outer"), KeyError.new("inner")))).to eq("runtime: outer")
    end

    it "skips a diagnostic that doesn't apply, so it can't block a more specific one" do
      described_class.register("StandardError", diagnostic("standard", applies: false))
      described_class.register("KeyError", diagnostic("key"))

      expect(found(wrapped(RuntimeError.new("outer"), KeyError.new("inner")))).to eq("key: inner")
    end

    it "skips a diagnostic whose `applies?` raises" do
      described_class.register("RuntimeError", diagnostic("runtime", applies: -> { raise "broken" }))
      described_class.register("StandardError", diagnostic("standard"))

      expect(found(RuntimeError.new("boom"))).to eq("standard: boom")
    end

    it "skips a diagnostic that fails to build" do
      described_class.register("RuntimeError", Class.new { def initialize(*) = raise("broken") })
      described_class.register("StandardError", diagnostic("standard"))

      expect(found(RuntimeError.new("boom"))).to eq("standard: boom")
    end

    it "applies a diagnostic with no `applies?`" do
      described_class.register("RuntimeError", Class.new {
        def initialize(*) = nil

        def fix = "always"
      })

      expect(found(RuntimeError.new("boom"))).to eq("always")
    end

    it "stops at a cause chain that loops" do
      outer = RuntimeError.new("outer")
      inner = KeyError.new("inner")
      allow(outer).to receive(:cause).and_return(inner)
      allow(inner).to receive(:cause).and_return(outer)

      expect(found(outer)).to be_nil
    end

    it "ignores anonymous classes in the ancestors" do
      described_class.register("RuntimeError", diagnostic("runtime"))

      expect(found(Class.new(RuntimeError).new("anon"))).to eq("runtime: anon")
    end
  end

  it "ships a diagnostic for the router's not found error" do
    expect(described_class.registry).to include("Hanami::Router::NotFoundError" => described_class::NotFound)
  end

  def wrapped(outer, cause)
    raise cause
  rescue cause.class
    begin
      raise outer
    rescue outer.class => error
      error
    end
  end
end
