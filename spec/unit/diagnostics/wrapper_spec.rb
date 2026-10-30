# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::Diagnostics::Wrapper do
  subject(:wrapper) { described_class.new(diagnostic) }

  # A diagnostic that returns the given parts. A part given as a lambda is called.
  def diagnostic_with(**parts)
    Class.new {
      parts.each do |name, value|
        define_method(name) { value.is_a?(Proc) ? instance_exec(&value) : value }
      end
    }.new
  end

  let(:diagnostic) { diagnostic_with }

  describe "with no parts" do
    it "reads every part as missing" do
      expect(wrapper.title).to be_nil
      expect(wrapper.explanation).to be_nil
      expect(wrapper.fix).to be_nil
      expect(wrapper.dataset).to be_nil
      expect(wrapper.runnable_fix?).to be(false)
    end
  end

  describe "text parts" do
    let(:diagnostic) { diagnostic_with(title: :a_symbol, explanation: "  ") }

    it "reads them as strings, and blank text as missing" do
      expect(wrapper.title).to eq("a_symbol")
      expect(wrapper.explanation).to be_nil
    end
  end

  describe "a part that raises" do
    let(:diagnostic) {
      Class.new {
        def title = raise("broken")

        def explanation = raise(NotImplementedError)

        def fix = runaway

        def dataset = {title: "Still here", rows: ["a"]}

        private

        def runaway = runaway
      }.new
    }

    it "costs only that part" do
      expect(wrapper.title).to be_nil
      expect(wrapper.explanation).to be_nil
      expect(wrapper.fix).to be_nil
      expect(wrapper.dataset.title).to eq("Still here")
    end
  end

  it "reads each part once" do
    calls = []
    wrapper = described_class.new(diagnostic_with(title: -> { calls << :title and "Title" }))

    2.times { wrapper.title }

    expect(calls).to eq([:title])
  end

  describe "#fix" do
    it "reads text as an unnamed fix" do
      wrapper = described_class.new(diagnostic_with(fix: "Do this."))

      expect(wrapper.fix).to have_attributes(name: nil, text: "Do this.")
    end

    it "reads a name and text" do
      wrapper = described_class.new(diagnostic_with(fix: {name: "Add a route", text: "Add it."}))

      expect(wrapper.fix).to have_attributes(name: "Add a route", text: "Add it.")
    end

    it "ignores a fix with a name but no text" do
      expect(described_class.new(diagnostic_with(fix: {name: "Add a route"})).fix).to be_nil
    end

    it "limits the text's length" do
      wrapper = described_class.new(diagnostic_with(fix: "x" * 20_000))

      expect(wrapper.fix.text.length).to eq(described_class::MAX_TEXT)
    end
  end

  describe "#dataset" do
    def dataset(value)
      described_class.new(diagnostic_with(dataset: value)).dataset
    end

    it "reads a table with columns" do
      expect(dataset({title: "Routes", columns: ["Method", "Path"], rows: [["GET", "/books"]]})).to have_attributes(
        title: "Routes", columns: ["Method", "Path"], rows: [["GET", "/books"]]
      )
    end

    it "reads a Hash as rows of two cells" do
      expect(dataset({title: "Pending", rows: {"a.rb" => 1}}).rows).to eq([["a.rb", "1"]])
    end

    it "reads strings as rows of one cell" do
      expect(dataset({title: "Paths", rows: ["app/templates", :lib]}).rows).to eq([["app/templates"], ["lib"]])
    end

    it "pads every row to the widest" do
      expect(dataset({title: "T", columns: ["A", "B", "C"], rows: [["1"], ["1", "2"]]}).rows).to eq(
        [["1", "", ""], ["1", "2", ""]]
      )
      expect(dataset({title: "T", columns: ["A"], rows: [["1", "2"]]}).columns).to eq(["A", ""])
    end

    it "gives a table with no title a generic one" do
      expect(dataset({rows: ["a"]}).title).to eq("Details")
    end

    it "ignores a table with no rows, or that isn't a Hash" do
      expect(dataset({title: "Empty", rows: []})).to be_nil
      expect(dataset([["a"]])).to be_nil
    end
  end

  describe "running the fix" do
    it "has a runnable fix with a fix and a run_fix" do
      wrapper = described_class.new(diagnostic_with(fix: "Do it.", run_fix: "Done"))

      expect(wrapper.runnable_fix?).to be(true)
      expect(wrapper.run_fix).to have_attributes(ok?: true, output: "Done")
    end

    it "ignores a run_fix with no fix to show it in" do
      wrapper = described_class.new(diagnostic_with(run_fix: "Done"))

      expect(wrapper.runnable_fix?).to be(false)
      expect(wrapper.run_fix).to have_attributes(ok?: false)
    end

    it "ignores a return value that isn't a string" do
      wrapper = described_class.new(diagnostic_with(fix: "Do it.", run_fix: true))

      expect(wrapper.run_fix).to have_attributes(ok?: true, output: "")
    end

    it "reports anything the fix raises as a failure" do
      [RuntimeError.new("boom"), SystemExit.new(1, "exit"), Interrupt.new].each do |error|
        wrapper = described_class.new(diagnostic_with(fix: "Do it.", run_fix: -> { raise error }))

        expect(wrapper.run_fix).to have_attributes(ok?: false, output: a_string_starting_with(error.class.name))
      end
    end
  end

  describe ".build" do
    let(:context) { Hanami::Webconsole::Diagnostics::Context.new(slice: nil) }

    it "is nil when the diagnostic doesn't apply" do
      diagnostic_class = Class.new {
        def initialize(*) = nil

        def applies? = false
      }

      expect(described_class.build(diagnostic_class, RuntimeError.new, context)).to be_nil
    end

    it "is nil when the diagnostic fails to build" do
      expect(described_class.build(Class.new { def initialize(*) = raise("no") }, RuntimeError.new, context)).to be_nil
    end
  end
end
