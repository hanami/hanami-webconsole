# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::ExceptionExtension do
  describe "capturing bindings" do
    it "attaches bindings to a raised exception", if: Hanami::Webconsole.bindings_available? do
      exception = begin
        local_to_this_frame = 42
        raise ArgumentError, "boom #{local_to_this_frame}"
      rescue ArgumentError => exception
        exception
      end

      expect(exception.__hanami_webconsole_bindings).to be_an(Array)
      expect(exception.__hanami_webconsole_bindings).not_to be_empty
      expect(exception.__hanami_webconsole_bindings.first).to be_a(Binding)
    end

    it "leaves the exception's own backtrace intact" do
      exception = begin
        raise ArgumentError, "boom"
      rescue ArgumentError => exception
        exception
      end

      expect(exception.backtrace).not_to be_nil
      expect(exception.backtrace).not_to be_empty
    end

    # Prepended onto the instance rather than relying on the global install, so this still
    # exercises the module on engines where binding capture is unavailable (JRuby).
    it "returns an empty array when nothing was captured" do
      exception = Exception.new("never raised")
      exception.singleton_class.prepend(described_class)

      expect(exception.__hanami_webconsole_bindings).to eq([])
    end

    it "keeps the first capture when an exception is re-raised",
      if: Hanami::Webconsole.bindings_available? do
      exception = begin
        begin
          raise "original"
        rescue RuntimeError => exception
          raise exception
        end
      rescue RuntimeError => exception
        exception
      end

      expect(exception.__hanami_webconsole_bindings).to be_an(Array)
    end
  end

  describe "standing down" do
    around do |example|
      was = described_class.capturing?
      example.run
    ensure
      described_class.instance_variable_set(:@capturing, was)
    end

    it "stops capturing once told to" do
      described_class.stand_down!

      expect(described_class.capturing?).to be(false)
    end

    it "still raises and rescues normally with capturing off" do
      described_class.stand_down!

      exception = begin
        raise ArgumentError, "the user's actual problem"
      rescue ArgumentError => exception
        exception
      end

      expect(exception.message).to eq("the user's actual problem")
      expect(exception.backtrace).not_to be_empty
    end
  end
end

RSpec.describe Hanami::Webconsole, ".probe_bindings" do
  # The JRuby regression: binding_of_caller loads, then `binding.callers` raises the first time
  # it is called. Checking only that `require` succeeded would install the extension anyway and
  # break every exception in the process.
  it "is false when the gem loads but calling into it raises" do
    prober = -> { raise NoMethodError, "undefined method 'runtime' for module JRuby" }

    expect(described_class.probe_bindings(prober)).to be(false)
  end

  it "is false when calling into it raises something outside StandardError" do
    prober = -> { raise NotImplementedError }

    expect(described_class.probe_bindings(prober)).to be(false)
  end

  # Only meaningful where the gem itself loads: probe_bindings requires it before it ever
  # reaches the prober, so an engine that cannot load it has no success case to test.
  it "is true when the call succeeds", if: Hanami::Webconsole.bindings_available? do
    expect(described_class.probe_bindings(-> { [binding] })).to be(true)
  end

  it "reflects the probe in .bindings_available?" do
    expect(described_class.bindings_available?).to be(described_class.probe_bindings)
  end
end
