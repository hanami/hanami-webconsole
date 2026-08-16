# frozen_string_literal: true

require "hanami/webconsole/inspector"

RSpec.describe Hanami::Webconsole::Inspector do
  subject(:inspector) { described_class }

  # Every object below is something the error page can plausibly meet in a development app, and
  # each one breaks a naive `object.inspect.to_s[0, limit]`.
  before do
    stub_const("Raiser", Class.new do
      def inspect
        raise "boom"
      end
    end)

    stub_const("FatalRaiser", Class.new do
      def inspect
        raise ::Exception, "not a StandardError"
      end
    end)

    stub_const("Overflower", Class.new do
      def inspect
        inspect
      end
    end)

    stub_const("Liar", Class.new do
      def class
        ::String
      end

      def inspect
        "#<Liar>"
      end
    end)

    stub_const("NonString", Class.new do
      def inspect
        42
      end
    end)

    stub_const("NilInspect", Class.new do
      def inspect
        nil
      end
    end)

    stub_const("Blank", Class.new(::BasicObject))

    stub_const("Counter", Class.new do
      def self.count
        @count ||= 0
      end

      def self.count!
        @count = count + 1
      end

      def inspect
        self.class.count!
        "#<Counter>"
      end
    end)
  end

  describe ".call" do
    it "inspects ordinary objects" do
      expect(inspector.call(nil)).to eq("nil")
      expect(inspector.call(true)).to eq("true")
      expect(inspector.call(42)).to eq("42")
      expect(inspector.call(:sym)).to eq(":sym")
      expect(inspector.call("hello")).to eq('"hello"')
      expect(inspector.call([1, "two", :three])).to eq('[1, "two", :three]')
      expect(inspector.call({"a" => 1})).to eq('{"a" => 1}')
      expect(inspector.call({})).to eq("{}")
      expect(inspector.call([])).to eq("[]")
    end

    it "always returns a valid UTF-8 String" do
      [nil, 1, "x", [1], {a: 1}, Object.new, Raiser.new, Blank.new].each do |object|
        result = inspector.call(object)

        expect(result).to be_a(String)
        expect(result).to be_valid_encoding
      end
    end

    it "truncates to the limit with a single-character ellipsis" do
      result = inspector.call("a" * 5_000, limit: 100)

      expect(result.length).to eq(100)
      expect(result).to end_with("…")
      expect(result).to start_with('"aaa')
    end

    it "does not truncate what already fits" do
      expect(inspector.call("abc", limit: 100)).to eq('"abc"')
    end

    it "defaults to a 2000 character limit" do
      expect(inspector.call("a" * 50_000).length).to eq(2_000)
    end

    it "tolerates degenerate limits" do
      expect(inspector.call("hello", limit: 0)).to eq("…")
      expect(inspector.call("hello", limit: -10)).to eq("…")
      expect(inspector.call("hello", limit: 1)).to eq("…")
      expect(inspector.call("hello", limit: nil).length).to be <= 2_000
      expect(inspector.call("hello", limit: "nonsense").length).to be <= 2_000
    end

    context "objects that fight back" do
      it "survives an #inspect that raises" do
        expect(inspector.call(Raiser.new)).to eq("#<Raiser (#inspect raised RuntimeError)>")
      end

      it "survives an #inspect that raises something other than StandardError" do
        expect(inspector.call(FatalRaiser.new)).to eq("#<FatalRaiser (#inspect raised Exception)>")
      end

      it "survives an #inspect that blows the stack" do
        # The class name is engine-specific: MRI raises SystemStackError, JRuby surfaces
        # Java::JavaLang::StackOverflowError. What matters is that we survive and name what hit us.
        expect(inspector.call(Overflower.new))
          .to match(/\A#<Overflower \(#inspect raised \S+\)>\z/)
      end

      it "survives an #inspect that returns a non-String" do
        expect(inspector.call(NonString.new)).to eq("#<NonString (#inspect returned Integer)>")
        expect(inspector.call(NilInspect.new)).to eq("#<NilInspect (#inspect returned NilClass)>")
      end

      it "survives a BasicObject with no #inspect and no #class" do
        # `Kernel#class` is bindable to a BasicObject even though the object cannot call it
        # itself, so we can still name it.
        expect(inspector.call(Blank.new)).to eq("#<Blank (#inspect raised NoMethodError)>")
      end

      it "reports the real class of an object that lies about #class" do
        expect(inspector.call(Liar.new)).to eq("#<Liar>")
      end

      it "does not treat a liar as a String" do
        liar = Class.new do
          def class
            ::String
          end

          def inspect
            "not a string at all"
          end
        end.new

        # A String would have come back quoted. Reaching String#byteslice on this object would
        # have raised instead.
        expect(inspector.call(liar)).to eq("not a string at all")
      end

      it "survives an object with no methods and a raising method_missing" do
        hostile = Class.new(::BasicObject) do
          def method_missing(*)
            ::Kernel.raise "no"
          end

          def respond_to_missing?(*)
            true
          end
        end.new

        expect(inspector.call(hostile)).to match(/\A#<#<Class:0x\h+> \(#inspect raised .+\)>\z/)
      end

      it "falls back to the placeholder when even the class cannot be named" do
        allow(inspector).to receive(:class_name).and_return(described_class::UNKNOWN_CLASS)

        expect(inspector.call(Raiser.new)).to eq(described_class::UNINSPECTABLE)
      end

      it "survives an #inspect returning invalid UTF-8" do
        object = Class.new do
          def inspect
            "bad \xC3( bytes".dup.force_encoding(Encoding::UTF_8)
          end
        end.new

        result = inspector.call(object)

        expect(result).to be_valid_encoding
        expect(result).to include("bytes")
      end

      it "transcodes a binary String" do
        result = inspector.call("caf\xC3\xA9".dup.force_encoding(Encoding::BINARY))

        expect(result).to be_valid_encoding
        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "inspects a String with invalid bytes without raising" do
        result = inspector.call("bad \xff bytes")

        expect(result).to be_valid_encoding
        expect(result).to include("bytes")
      end
    end

    context "recursive structures" do
      it "survives a self-referential array" do
        array = []
        array << array

        expect(inspector.call(array)).to eq("[[...]]")
      end

      it "survives a self-referential hash" do
        hash = {}
        hash["self"] = hash

        expect(inspector.call(hash)).to eq('{"self" => {...}}')
      end

      it "survives mutual recursion" do
        a = []
        b = [a]
        a << b

        expect(inspector.call(a)).to eq("[[[...]]]")
      end

      it "does not mistake a repeated sibling for a cycle" do
        shared = [1]

        expect(inspector.call([shared, shared])).to eq("[[1], [1]]")
      end

      it "caps deeply nested structures instead of exhausting the stack" do
        array = []
        5_000.times { array = [array] }

        expect { inspector.call(array) }.not_to raise_error
        expect(inspector.call(array).length).to be <= 2_000
      end
    end

    context "enormous collections" do
      it "does not inspect every element of a huge array" do
        huge = Array.new(200_000) { Counter.new }

        result = inspector.call(huge, limit: 200)

        expect(result.length).to eq(200)
        expect(result).to end_with("…")
        # The naive implementation calls #inspect 200_000 times before truncating.
        expect(Counter.count).to be < 1_000
      end

      it "does not inspect every pair of a huge hash" do
        huge = {}
        10_000.times { |i| huge[i] = Counter.new }

        expect(inspector.call(huge, limit: 200).length).to eq(200)
        expect(Counter.count).to be < 1_000
      end

      it "keeps a huge array's output well formed" do
        result = inspector.call((1..1_000_000).to_a, limit: 60)

        expect(result).to start_with("[1, 2, 3,")
        expect(result).to end_with("…")
        expect(result.length).to eq(60)
      end

      it "does not build the whole string for an enormous String" do
        huge = "x" * 5_000_000

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = inspector.call(huge, limit: 80)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(result.length).to eq(80)
        expect(elapsed).to be < 1.0
      end

      it "isolates a raising element inside a collection" do
        result = inspector.call([1, Raiser.new, 3])

        expect(result).to eq("[1, #<Raiser (#inspect raised RuntimeError)>, 3]")
      end

      it "isolates a raising hash key" do
        result = inspector.call({Raiser.new => "value"})

        expect(result).to eq('{#<Raiser (#inspect raised RuntimeError)> => "value"}')
      end

      it "truncates long values nested in a collection" do
        result = inspector.call({"key" => "v" * 5_000}, limit: 50)

        expect(result.length).to eq(50)
        expect(result).to start_with('{"key" => "vvv')
      end
    end

    context "collection subclasses" do
      it "iterates with the real Array#each" do
        klass = Class.new(Array) do
          def each(*)
            raise "nope"
          end

          def inspect
            raise "nope"
          end
        end

        expect(inspector.call(klass[1, 2])).to eq("[1, 2]")
      end

      it "iterates with the real Hash#each_pair" do
        klass = Class.new(Hash) do
          def each_pair(*)
            raise "nope"
          end

          def inspect
            raise "nope"
          end
        end

        hash = klass.new
        hash["a"] = 1

        expect(inspector.call(hash)).to eq('{"a" => 1}')
      end

      it "inspects a String subclass with the real String#inspect" do
        klass = Class.new(String) do
          def inspect
            raise "nope"
          end
        end

        expect(inspector.call(klass.new("hi"))).to eq('"hi"')
      end
    end
  end

  describe ".class_name" do
    it "returns the class name" do
      expect(inspector.class_name(nil)).to eq("NilClass")
      expect(inspector.class_name("x")).to eq("String")
      expect(inspector.class_name(1)).to eq("Integer")
      expect(inspector.class_name(Raiser.new)).to eq("Raiser")
    end

    it "returns the real class name of an object that lies about #class" do
      expect(inspector.class_name(Liar.new)).to eq("Liar")
    end

    it "returns the class of a class object" do
      # Class objects are not special-cased: `String.class` really is `Class`.
      expect(inspector.class_name(String)).to eq("Class")
    end

    it "names an anonymous class" do
      expect(inspector.class_name(Class.new.new)).to match(/\A#<Class:0x\h+>\z/)
    end

    it "names a BasicObject, which cannot answer #class itself" do
      expect(inspector.class_name(Blank.new)).to eq("Blank")
    end

    it "does not raise for an object whose class raises on #name" do
      klass = Class.new do
        def self.name
          raise "no name for you"
        end
      end

      expect(inspector.class_name(klass.new)).to be_a(String)
    end

    it "never raises for anything" do
      [nil, false, 1, :a, "s", [], {}, Object.new, Blank.new, Raiser.new].each do |object|
        expect { inspector.class_name(object) }.not_to raise_error
      end
    end
  end
end
