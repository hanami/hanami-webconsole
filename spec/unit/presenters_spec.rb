# frozen_string_literal: true

require "hanami/webconsole/presenters"

RSpec.describe Hanami::Webconsole::Presenters do
  let(:presenter_class) { Class.new(Hanami::Webconsole::Presenters::Base) }

  # Every example but the default registry's own starts from an empty registry. Restoring it is
  # the suite-wide hook's job (see spec/support/presenters.rb).
  around do |example|
    Hanami::Webconsole::Presenters.reset! unless self.class.metadata[:default_registry]

    example.run
  end

  describe "the default registry", :default_registry do
    it "registers the presenters that ship with the gem" do
      expect(described_class.registered).to eq(
        "Hanami::Router::NotFoundError" => Hanami::Webconsole::Presenters::NotFound
      )
    end

    it "leaves every other error to the generic path" do
      expect(described_class.for(RuntimeError.new("boom"))).to be_nil
    end
  end

  describe ".register" do
    it "returns the presenter class" do
      expect(described_class.register("ArgumentError", presenter_class)).to be(presenter_class)
    end

    it "accepts a class rather than a name" do
      described_class.register(ArgumentError, presenter_class)

      expect(described_class.for(ArgumentError.new("boom"))).to be_a(presenter_class)
    end
  end

  describe ".for" do
    it "returns an instance of the registered presenter" do
      described_class.register("ArgumentError", presenter_class)

      presenter = described_class.for(ArgumentError.new("boom"))

      expect(presenter).to be_a(presenter_class)
    end

    it "gives the presenter the exception" do
      described_class.register("ArgumentError", presenter_class)
      exception = ArgumentError.new("boom")

      expect(described_class.for(exception).exception).to be(exception)
    end

    it "returns nil for an unregistered exception" do
      described_class.register("ArgumentError", presenter_class)

      expect(described_class.for(TypeError.new("boom"))).to be_nil
    end

    it "matches a subclass against a registered superclass" do
      described_class.register("ArgumentError", presenter_class)
      subclass = Class.new(ArgumentError)

      expect(described_class.for(subclass.new("boom"))).to be_a(presenter_class)
    end

    it "prefers the most specific registration" do
      specific = Class.new(Hanami::Webconsole::Presenters::Base)
      described_class.register("StandardError", presenter_class)
      described_class.register("ArgumentError", specific)

      expect(described_class.for(ArgumentError.new("boom"))).to be_a(specific)
    end

    it "returns nil rather than raising when a presenter cannot be built" do
      broken = Class.new(Hanami::Webconsole::Presenters::Base) do
        def initialize(exception)
          super
          raise "nope"
        end
      end
      described_class.register("ArgumentError", broken)

      expect(described_class.for(ArgumentError.new("boom"))).to be_nil
    end

    it "returns nil for an anonymous exception class" do
      exception = Class.new(StandardError).new("boom")
      described_class.register("ArgumentError", presenter_class)

      expect(described_class.for(exception)).to be_nil
    end
  end

  describe Hanami::Webconsole::Presenters::Base do
    subject(:presenter) { described_class.new(exception) }

    let(:exception) { RuntimeError.new("boom") }

    it "exposes the exception" do
      expect(presenter.exception).to be(exception)
    end

    it "defaults every nullable part of the interface to nil" do
      expect(presenter.headline).to be_nil
      expect(presenter.lede).to be_nil
      expect(presenter.command).to be_nil
      expect(presenter.snippet).to be_nil
      expect(presenter.note).to be_nil
    end

    it "defaults every list part of the interface to an empty array" do
      expect(presenter.items).to eq([])
      expect(presenter.suggestions).to eq([])
      expect(presenter.context_panels).to eq([])
    end
  end
end
