# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::Text do
  def blocks(text)
    described_class.blocks(text).map { |block| [block.type, block.lines, block.language] }
  end

  it "reads paragraphs, split by blank lines" do
    expect(blocks("One.\n\nTwo.")).to eq([[:paragraph, ["One."], nil], [:paragraph, ["Two."], nil]])
  end

  it "keeps the lines of a paragraph" do
    expect(blocks("First line\nSecond line")).to eq([[:paragraph, ["First line", "Second line"], nil]])
  end

  it "reads a list" do
    expect(blocks("- a\n- b")).to eq([[:list, ["a", "b"], nil]])
  end

  it "reads an indented list, as `TemplateNotFoundError` writes one" do
    expect(blocks(" - app/templates\n - slices/main/templates")).to eq(
      [[:list, ["app/templates", "slices/main/templates"], nil]]
    )
  end

  it "reads a list that follows a paragraph line directly" do
    expect(blocks("Paths:\n- a\n- b")).to eq([[:paragraph, ["Paths:"], nil], [:list, ["a", "b"], nil]])
  end

  it "joins an indented line onto the list item before it" do
    expect(blocks("- a long\n  item\n- b")).to eq([[:list, ["a long item", "b"], nil]])
  end

  it "reads a fenced code block, with its language" do
    expect(blocks("Run:\n\n```sh\nbundle exec hanami db migrate\n```")).to eq(
      [[:paragraph, ["Run:"], nil], [:code, ["bundle exec hanami db migrate"], "sh"]]
    )
  end

  it "reads a fence with no blank line before it, and keeps blank lines inside it" do
    expect(blocks("Add:\n```ruby\na\n\nb\n```\nDone.")).to eq(
      [[:paragraph, ["Add:"], nil], [:code, ["a", "", "b"], "ruby"], [:paragraph, ["Done."], nil]]
    )
  end

  it "reads a fence with no language" do
    expect(blocks("```\ncode\n```")).to eq([[:code, ["code"], nil]])
  end

  it "reads an unclosed fence to the end" do
    expect(blocks("```ruby\ncode")).to eq([[:code, ["code"], "ruby"]])
  end

  it "reads an indented paragraph as code, without its indent" do
    expect(blocks("Query:\n\n    SELECT *\n      FROM books")).to eq(
      [[:paragraph, ["Query:"], nil], [:code, ["SELECT *", "  FROM books"], nil]]
    )
  end

  it "leaves emphasis and links as text" do
    expect(blocks("*not* _emphasis_ [or](a link)")).to eq([[:paragraph, ["*not* _emphasis_ [or](a link)"], nil]])
  end

  it "reads nothing from nil or blank text" do
    expect(blocks(nil)).to eq([])
    expect(blocks("\n  \n")).to eq([])
  end

  it "reads Windows line endings" do
    expect(blocks("One.\r\n\r\nTwo.")).to eq([[:paragraph, ["One."], nil], [:paragraph, ["Two."], nil]])
  end

  describe ".shell?" do
    it "is true for a shell code block" do
      %w[sh shell bash console].each do |language|
        expect(described_class.shell?(described_class.blocks("```#{language}\nls\n```").first)).to be(true)
      end
    end

    it "is false for other code blocks" do
      expect(described_class.shell?(described_class.blocks("```ruby\na\n```").first)).to be(false)
      expect(described_class.shell?(described_class.blocks("    a").first)).to be(false)
    end
  end
end
