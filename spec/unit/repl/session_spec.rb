# frozen_string_literal: true

require "hanami/webconsole/repl/session"

RSpec.describe Hanami::Webconsole::Repl::Session do
  subject(:session) { described_class.new(frame_binding) }

  # Stands in for the binding of a backtrace frame, with one local to reach for.
  let(:frame_binding) { binding_with_local("Ruby") }

  def binding_with_local(book)
    binding
  end

  # Owned by another workstream; stubbed so this spec stands alone. See CONTRACTS.md.
  before do
    inspector = Module.new do
      def self.call(object, limit: 2_000)
        object.inspect
      end

      def self.class_name(object)
        object.class.name
      end
    end

    stub_const("Hanami::Webconsole::Inspector", inspector)
  end

  describe "#eval" do
    it "evaluates against the frame's binding" do
      expect(session.eval("book")).to eq(['"Ruby"', false])
    end

    it "runs the result through the inspector" do
      expect(Hanami::Webconsole::Inspector).to receive(:call).with(3).and_return("3")

      expect(session.eval("1 + 2")).to eq(["3", false])
    end

    it "sees local variables assigned in an earlier call" do
      session.eval("author = 'Matz'")

      expect(session.eval("author")).to eq(['"Matz"', false])
    end

    it "returns nil's inspection rather than an empty string" do
      expect(session.eval("nil")).to eq(["nil", false])
    end

    it "handles empty source" do
      expect(session.eval("")).to eq(["nil", false])
    end

    it "coerces non-string source" do
      expect(session.eval(nil)).to eq(["nil", false])
    end

    it "formats a StandardError" do
      expect(session.eval("raise ArgumentError, 'nope'")).to eq(["ArgumentError: nope", true])
    end

    it "formats a NameError from an unknown local" do
      output, error = session.eval("nope")

      expect(error).to be(true)
      expect(output).to start_with("NameError: ")
    end

    it "formats a SyntaxError, which a bare rescue would miss" do
      output, error = session.eval("[1, 2")

      expect(error).to be(true)
      expect(output).to start_with("SyntaxError: ")
    end

    it "formats a SystemStackError" do
      expect(session.eval("raise SystemStackError, 'stack level too deep'"))
        .to eq(["SystemStackError: stack level too deep", true])
    end

    it "formats a NoMemoryError" do
      expect(session.eval("raise NoMemoryError, 'failed to allocate memory'"))
        .to eq(["NoMemoryError: failed to allocate memory", true])
    end

    it "formats a bare Exception" do
      expect(session.eval("raise Exception, 'not a StandardError'"))
        .to eq(["Exception: not a StandardError", true])
    end

    it "formats an exception with no message as its class name alone" do
      klass = Class.new(StandardError) do
        def message
          ""
        end
      end
      stub_const("SpecSilentError", klass)

      expect(session.eval("raise SpecSilentError")).to eq(["SpecSilentError", true])
    end

    it "survives an exception whose message raises" do
      klass = Class.new(StandardError) do
        def message
          raise "message raised"
        end
      end
      stub_const("SpecUnprintableError", klass)

      expect(session.eval("raise SpecUnprintableError")).to eq(["SpecUnprintableError", true])
    end

    it "reports an inspector that blows up rather than raising" do
      allow(Hanami::Webconsole::Inspector).to receive(:call).and_raise(NotImplementedError, "nope")

      output, error = session.eval("1")

      expect(error).to be(true)
      expect(output).to eq("NotImplementedError: nope")
    end

    it "does not leak the console's own filename into unrelated output" do
      output, = session.eval("__FILE__")

      expect(output).to eq('"(hanami-webconsole)"')
    end
  end
end
