# frozen_string_literal: true

RSpec.describe Hanami::Diagnostics::Text do
  def blocks(text)
    described_class.blocks(text).map { |block| [block.type, block.lines, block.language] }
  end

  it "reads paragraphs, split by blank lines" do
    expect(blocks("One.\n\nTwo.")).to eq(
      [
        [:paragraph, ["One."], nil],
        [:paragraph, ["Two."], nil]
      ]
    )
  end

  it "keeps the lines of a paragraph" do
    expect(blocks("First line\nSecond line")).to eq([[:paragraph, ["First line", "Second line"], nil]])
  end

  it "reads a list" do
    expect(blocks("- a\n- b")).to eq([[:list, ["a", "b"], nil]])
  end

  it "reads an indented list" do
    expect(blocks(" - app/templates\n - slices/main/templates")).to eq(
      [[:list, ["app/templates", "slices/main/templates"], nil]]
    )
  end

  it "reads a list that follows a paragraph line directly" do
    expect(blocks("Paths:\n- a\n- b")).to eq(
      [
        [:paragraph, ["Paths:"], nil],
        [:list, ["a", "b"], nil]
      ]
    )
  end

  it "keeps a line as part of the list item before it, with its line break" do
    expect(blocks("- a long\n  item\n- b\nmore")).to eq([[:list, ["a long\nitem", "b\nmore"], nil]])
  end

  it "ends a list at a blank line" do
    expect(blocks("- a\n\nAfter.")).to eq(
      [
        [:list, ["a"], nil],
        [:paragraph, ["After."], nil]
      ]
    )
  end

  it "reads a fenced code block, with its language" do
    expect(blocks("Run:\n\n```sh\nbundle exec hanami db migrate\n```")).to eq(
      [
        [:paragraph, ["Run:"], nil],
        [:code, ["bundle exec hanami db migrate"], "sh"]
      ]
    )
  end

  it "reads a fence with no blank line before it, and keeps blank lines inside it" do
    expect(blocks("Add:\n```ruby\na\n\nb\n```\nDone.")).to eq(
      [
        [:paragraph, ["Add:"], nil],
        [:code, ["a", "", "b"], "ruby"],
        [:paragraph, ["Done."], nil]
      ]
    )
  end

  it "reads a fence with no language" do
    expect(blocks("```\ncode\n```")).to eq([[:code, ["code"], nil]])
  end

  it "reads the language from the first word of a fence's info string" do
    expect(blocks("```Ruby title=x\nputs 1\n```")).to eq([[:code, ["puts 1"], "ruby"]])
  end

  it "closes a fence only with a fence at least as long as the one opening it" do
    expect(blocks("````md\n```\ninner\n```\n````")).to eq([[:code, ["```", "inner", "```"], "md"]])
  end

  it "reads an unclosed fence as text, so it can't hide the rest of the text" do
    expect(blocks("Failed near:\n```\nsome text\n\nThe rest")).to eq(
      [
        [:paragraph, ["Failed near:", "```", "some text"], nil],
        [:paragraph, ["The rest"], nil]
      ]
    )
  end

  it "reads indented lines as text, not code" do
    expect(blocks("Query:\n\n    SELECT *\n      FROM books")).to eq(
      [
        [:paragraph, ["Query:"], nil],
        [:paragraph, ["    SELECT *", "      FROM books"], nil]
      ]
    )
  end

  it "removes the shared indent from an indented fence's code" do
    expect(blocks("- Add:\n  ```ruby\n  def call\n    foo\n  end\n  ```")).to eq(
      [
        [:list, ["Add:"], nil],
        [:code, ["def call", "  foo", "end"], "ruby"]
      ]
    )
  end

  it "leaves emphasis and links as text" do
    expect(blocks("*not* _emphasis_ [or](a link)")).to eq(
      [[:paragraph, ["*not* _emphasis_ [or](a link)"], nil]]
    )
  end

  it "reads nothing from nil or blank text" do
    expect(blocks(nil)).to eq([])
    expect(blocks("\n  \n")).to eq([])
  end

  it "reads Windows line endings" do
    expect(blocks("One.\r\n\r\nTwo.")).to eq(
      [
        [:paragraph, ["One."], nil],
        [:paragraph, ["Two."], nil]
      ]
    )
  end

  describe ".unclosed_fence" do
    it "returns the fence that would close the text's open code block" do
      expect(described_class.unclosed_fence("Run:\n````sh\nls")).to eq("````")
    end

    it "returns nil when every fence is closed" do
      expect(described_class.unclosed_fence("```sh\nls\n```\nDone.")).to be_nil
      expect(described_class.unclosed_fence("No fences.")).to be_nil
    end
  end

  describe "with any text" do
    # Returns the text's non-whitespace characters, without fence lines, which the parser either
    # removes (around a code block) or keeps as text (when unclosed).
    def characters(text)
      text.split("\n").grep_v(/\A\s*`{3,}[^`]*\z/).join.gsub(/\s+/, "")
    end

    # Returns the given blocks as text again, with a `- ` before each list item.
    def rebuild(blocks)
      blocks.map { |block|
        block.type == :list ? block.lines.map { |item| "- #{item}" }.join("\n") : block.lines.join("\n")
      }.join("\n")
    end

    tokens = ["- ", " - ", "```", "```ruby", "````", "    ", "\t", "^", "~~", "|", "+-", "a", "b c", ":", "  ", "`x`", "'y'", ""]
    random = Random.new(1234)
    texts = Array.new(1_000) {
      Array.new(random.rand(1..8)) { Array.new(random.rand(0..4)) { tokens.sample(random:) }.join }.join("\n")
    }

    it "never loses or reorders text" do
      texts.each do |text|
        expect(characters(rebuild(described_class.blocks(text)))).to eq(characters(text)), text.inspect
      end
    end
  end

  describe ".shell?" do
    it "is true for a shell code block" do
      %w[sh shell bash console].each do |language|
        expect(described_class.shell?(described_class.blocks("```#{language}\nls\n```").first)).to be(true)
      end
    end

    it "is false for other code blocks" do
      expect(described_class.shell?(described_class.blocks("```ruby\na\n```").first)).to be(false)
      expect(described_class.shell?(described_class.blocks("```\na\n```").first)).to be(false)
    end
  end
end
