# frozen_string_literal: true

RSpec.describe Hanami::Diagnostics::Wrapper do
  # Wraps a diagnostic that returns the given parts. A part given as a lambda is called.
  def wrapper_for(**parts)
    diagnostic = Class.new {
      parts.each do |name, value|
        define_method(name) { value.is_a?(Proc) ? instance_exec(&value) : value }
      end
    }.new

    described_class.new(diagnostic)
  end

  it "reads every part as missing, for a diagnostic with no parts" do
    wrapper = wrapper_for

    expect(wrapper.title).to be_nil
    expect(wrapper.explanation).to be_nil
    expect(wrapper.fix).to be_nil
    expect(wrapper.dataset).to be_nil
    expect(wrapper.runnable_fix?).to be(false)
  end

  it "reads text parts as strings, and blank text as missing" do
    wrapper = wrapper_for(title: :a_symbol, explanation: "  ")

    expect(wrapper.title).to eq("a_symbol")
    expect(wrapper.explanation).to be_nil
  end

  it "reads an explanation given as an array of parts" do
    expect(wrapper_for(explanation: ["One.", nil, "Two."]).explanation).to eq("One.\n\nTwo.")
  end

  it "reads the title as a single line of plain text" do
    expect(wrapper_for(title: " A short\nname ").title).to eq("A short name")
    expect(wrapper_for(title: "```ruby").title).to eq("```ruby")
    expect(wrapper_for(title: "\n").title).to be_nil
  end

  it "reads a part that raises as missing, and keeps the other parts" do
    runaway = -> { runaway.call }
    wrapper = wrapper_for(
      title: -> { raise "broken" },
      explanation: -> { raise NotImplementedError },
      fix: runaway,
      dataset: {title: "Still here", rows: ["a"]}
    )

    expect(wrapper.title).to be_nil
    expect(wrapper.explanation).to be_nil
    expect(wrapper.fix).to be_nil
    expect(wrapper.dataset.title).to eq("Still here")
  end

  it "reads each part only once" do
    calls = []
    wrapper = wrapper_for(title: -> { calls << :title and "Title" })

    2.times { wrapper.title }

    expect(calls).to eq([:title])
  end

  describe "#fix" do
    it "reads text as an unnamed fix" do
      expect(wrapper_for(fix: "Do this.").fix).to have_attributes(name: nil, text: "Do this.")
    end

    it "reads a name and text" do
      expect(wrapper_for(fix: {name: "Add a route", text: "Add it."}).fix)
        .to have_attributes(name: "Add a route", text: "Add it.")
    end

    it "reads the name as a single line of plain text" do
      expect(wrapper_for(fix: {name: "Add a\nroute", text: "Add it."}).fix.name).to eq("Add a route")
    end

    it "reads text given as an array of parts" do
      fix = wrapper_for(fix: {name: "Generate action", text: ["Generate it:", {sh: "hanami generate action"}]}).fix

      expect(fix).to have_attributes(name: "Generate action", text: "Generate it:\n\n```sh\nhanami generate action\n```")
    end

    it "ignores a fix whose parts are all blank" do
      expect(wrapper_for(fix: [nil, "", []]).fix).to be_nil
    end

    it "ignores a fix with a name but no text" do
      expect(wrapper_for(fix: {name: "Add a route"}).fix).to be_nil
    end

    it "is destructive only when the fix says destructive: true" do
      expect(wrapper_for(fix: "Do it.").fix.destructive).to be(false)
      expect(wrapper_for(fix: {text: "Do it.", destructive: "yes"}).fix.destructive).to be(false)
      expect(wrapper_for(fix: {text: "Do it.", destructive: true}).fix.destructive).to be(true)
    end

    it "limits the text's length" do
      expect(wrapper_for(fix: "x" * 20_000).fix.text.length).to eq(described_class::MAX_TEXT)
    end

    it "limits the text's length at the end of a line" do
      expect(wrapper_for(fix: "first line\n" + "x" * 20_000).fix.text).to eq("first line")
    end

    it "closes a code fence that the limit leaves open" do
      text = wrapper_for(fix: "Run:\n\n```sh\n" + "echo hi\n" * 2_000).fix.text

      expect(text).to end_with("echo hi\n```")
      expect(Hanami::Diagnostics::Text.blocks(text + "\n\nAfter").last)
        .to have_attributes(type: :paragraph, lines: ["After"])
    end
  end

  describe "#dataset" do
    def dataset_for(value)
      wrapper_for(dataset: value).dataset
    end

    it "reads a table with columns" do
      dataset = dataset_for({title: "Routes", columns: ["Method", "Path"], rows: [["GET", "/books"]]})

      expect(dataset).to have_attributes(title: "Routes", columns: ["Method", "Path"], rows: [["GET", "/books"]])
    end

    it "reads a Hash as rows of two cells" do
      expect(dataset_for({title: "Pending", rows: {"a.rb" => 1}}).rows).to eq([["a.rb", "1"]])
    end

    it "reads strings as rows of one cell" do
      expect(dataset_for({title: "Paths", rows: ["app/templates", :lib]}).rows).to eq(
        [
          ["app/templates"],
          ["lib"]
        ]
      )
    end

    it "pads every row to the widest" do
      expect(dataset_for({title: "T", columns: ["A", "B", "C"], rows: [["1"], ["1", "2"]]}).rows).to eq(
        [
          ["1", "", ""],
          ["1", "2", ""]
        ]
      )
    end

    it "pads the columns to the widest row" do
      expect(dataset_for({title: "T", columns: ["A"], rows: [["1", "2"]]}).columns).to eq(["A", ""])
    end

    it "limits the number of rows" do
      stub_const("#{described_class}::MAX_ROWS", 2)

      expect(dataset_for({rows: ["a", "b", "c"]}).rows).to eq([["a"], ["b"]])
    end

    it "gives a table with no title a generic one" do
      expect(dataset_for({rows: ["a"]}).title).to eq("Details")
    end

    it "reads the title as a single line of plain text" do
      expect(dataset_for({title: "All\nroutes", rows: ["a"]}).title).to eq("All routes")
    end

    it "ignores a table with no rows, or that isn't a Hash" do
      expect(dataset_for({title: "Empty", rows: []})).to be_nil
      expect(dataset_for([["a"]])).to be_nil
    end
  end

  describe "#run_fix" do
    it "runs the fix, when there's a fix to show it in" do
      wrapper = wrapper_for(fix: "Do it.", run_fix: "Done")

      expect(wrapper.runnable_fix?).to be(true)
      expect(wrapper.run_fix).to have_attributes(ok?: true, output: "Done")
    end

    it "ignores a run_fix with no fix to show it in" do
      wrapper = wrapper_for(run_fix: "Done")

      expect(wrapper.runnable_fix?).to be(false)
      expect(wrapper.run_fix).to have_attributes(ok?: false)
    end

    it "ignores a return value that isn't a string" do
      expect(wrapper_for(fix: "Do it.", run_fix: true).run_fix).to have_attributes(ok?: true, output: "")
    end

    it "reports anything the fix raises as a failure" do
      [RuntimeError.new("boom"), SystemExit.new(1, "exit"), Interrupt.new].each do |error|
        wrapper = wrapper_for(fix: "Do it.", run_fix: -> { raise error })

        expect(wrapper.run_fix).to have_attributes(ok?: false, output: a_string_starting_with(error.class.name))
      end
    end
  end
end
