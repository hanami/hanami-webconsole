# frozen_string_literal: true

require "hanami/webconsole/editor"

RSpec.describe Hanami::Webconsole::Editor do
  describe "#url" do
    it "builds a VS Code link by default" do
      expect(described_class.new.url("/app/lib/books.rb", 12))
        .to eq("vscode://file//app/lib/books.rb:12")
    end

    it "builds a Cursor link" do
      expect(described_class.new(:cursor).url("/app/lib/books.rb", 12))
        .to eq("cursor://file//app/lib/books.rb:12")
    end

    # Zed takes everything after `zed://file` as the path, and reads a `:line` suffix from it.
    it "builds a Zed link" do
      expect(described_class.new(:zed).url("/app/my app/books.rb", 12))
        .to eq("zed://file/app/my%20app/books.rb:12")
    end

    it "builds a TextMate link" do
      expect(described_class.new(:txmt).url("/app/lib/books.rb", 12))
        .to eq("txmt://open?url=file://%2Fapp%2Flib%2Fbooks.rb&line=12")
    end

    it "builds a Sublime Text link" do
      expect(described_class.new(:subl).url("/app/lib/books.rb", 12))
        .to eq("subl://open?url=file://%2Fapp%2Flib%2Fbooks.rb&line=12")
    end

    it "escapes characters that would break the URL, keeping path separators" do
      expect(described_class.new(:vscode).url("/app/my app/books.rb", 3))
        .to eq("vscode://file//app/my%20app/books.rb:3")
    end

    it "defaults the line to 1" do
      expect(described_class.new.url("/app/lib/books.rb")).to end_with(":1")
    end

    it "coerces a non-numeric line" do
      expect(described_class.new.url("/app/lib/books.rb", nil)).to end_with(":0")
    end
  end

  describe "editor selection" do
    it "accepts a string or a symbol" do
      expect(described_class.new("cursor").name).to eq(:cursor)
      expect(described_class.new(:cursor).name).to eq(:cursor)
    end

    it "accepts aliases" do
      expect(described_class.new(:code).name).to eq(:vscode)
      expect(described_class.new(:sublime).name).to eq(:subl)
      expect(described_class.new(:textmate).name).to eq(:txmt)
    end

    it "ignores surrounding whitespace and case" do
      expect(described_class.new(" VSCode \n").name).to eq(:vscode)
    end

    it "falls back to the default for an unknown editor, rather than raising" do
      expect(described_class.new(:ed).name).to eq(:vscode)
      expect(described_class.new(nil).name).to eq(:vscode)
    end
  end

  describe ".from_env" do
    it "reads HANAMI_EDITOR" do
      expect(described_class.from_env("HANAMI_EDITOR" => "subl").name).to eq(:subl)
    end

    it "defaults when no editor is set" do
      expect(described_class.from_env({}).name).to eq(:vscode)
    end

    it "falls back to the command in VISUAL or EDITOR" do
      expect(described_class.from_env("EDITOR" => "zed").name).to eq(:zed)
      expect(described_class.from_env("EDITOR" => "/usr/local/bin/code -w").name).to eq(:vscode)
      expect(described_class.from_env("VISUAL" => "subl -w", "EDITOR" => "zed").name).to eq(:subl)
    end

    it "prefers HANAMI_EDITOR over VISUAL and EDITOR" do
      expect(described_class.from_env("HANAMI_EDITOR" => "cursor", "EDITOR" => "zed").name).to eq(:cursor)
    end

    it "skips an editor command it can't link to" do
      expect(described_class.from_env("VISUAL" => "vim", "EDITOR" => "zed").name).to eq(:zed)
      expect(described_class.from_env("EDITOR" => "vim").name).to eq(:vscode)
    end
  end
end
