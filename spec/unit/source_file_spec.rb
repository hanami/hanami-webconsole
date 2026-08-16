# frozen_string_literal: true

require "hanami/webconsole/source_file"
require "fileutils"
require "tmpdir"

RSpec.describe Hanami::Webconsole::SourceFile do
  subject(:source_file) { described_class }

  around do |example|
    Dir.mktmpdir("hanami-webconsole") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(name, content)
    path = File.join(tmpdir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def numbered_file(count = 40)
    write("numbered.rb", Array.new(count) { |i| "line #{i + 1}" }.join("\n") + "\n")
  end

  describe ".read" do
    it "returns the lines around the given one" do
      path = numbered_file

      excerpt = source_file.read(path, around: 20)

      expect(excerpt.path).to eq(path)
      expect(excerpt.first_lineno).to eq(13)
      expect(excerpt.highlight_lineno).to eq(20)
      expect(excerpt.lines.length).to eq(15)
      expect(excerpt.lines.first).to eq("line 13")
      expect(excerpt.lines.last).to eq("line 27")
    end

    it "strips trailing newlines from the lines" do
      path = write("crlf.rb", "alpha\r\nbeta\r\ngamma\r\n")

      excerpt = source_file.read(path, around: 2, context: 1)

      expect(excerpt.lines).to eq(["alpha", "beta", "gamma"])
    end

    it "honours the context argument" do
      excerpt = source_file.read(numbered_file, around: 20, context: 2)

      expect(excerpt.first_lineno).to eq(18)
      expect(excerpt.lines).to eq(["line 18", "line 19", "line 20", "line 21", "line 22"])
    end

    it "clamps at the start of the file" do
      excerpt = source_file.read(numbered_file, around: 2)

      expect(excerpt.first_lineno).to eq(1)
      expect(excerpt.lines.first).to eq("line 1")
      expect(excerpt.highlight_lineno).to eq(2)
    end

    it "clamps at the end of the file" do
      excerpt = source_file.read(numbered_file(10), around: 9)

      expect(excerpt.first_lineno).to eq(2)
      expect(excerpt.lines.last).to eq("line 10")
    end

    it "returns nil when the line is past the end of the file" do
      expect(source_file.read(numbered_file(10), around: 500)).to be_nil
    end

    it "returns nil for a missing file" do
      expect(source_file.read(File.join(tmpdir, "nope.rb"), around: 1)).to be_nil
    end

    it "returns nil for a directory" do
      expect(source_file.read(tmpdir, around: 1)).to be_nil
    end

    it "returns nil for an empty file" do
      expect(source_file.read(write("empty.rb", ""), around: 1)).to be_nil
    end

    it "returns nil for a binary file" do
      path = write("binary.bin", "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR")

      expect(source_file.read(path, around: 1)).to be_nil
    end

    it "returns nil for invalid UTF-8" do
      path = write("invalid.rb", "puts \xC3\x28\n")

      expect(source_file.read(path, around: 1)).to be_nil
    end

    it "returns nil for a file larger than the cap" do
      path = write("huge.rb", "x" * (described_class::MAX_SIZE + 1))

      expect(source_file.read(path, around: 1)).to be_nil
    end

    it "reads a file just under the cap" do
      line = "#{"x" * 99}\n"
      path = write("big.rb", line * 1_000)

      expect(source_file.read(path, around: 1)).not_to be_nil
    end

    it "returns nil rather than raising for a nil path" do
      expect(source_file.read(nil, around: 1)).to be_nil
    end

    it "returns nil rather than raising for a nil line number" do
      expect(source_file.read(numbered_file, around: nil)).to be_nil
    end

    it "returns nil for a non-positive line number" do
      expect(source_file.read(numbered_file, around: 0)).to be_nil
      expect(source_file.read(numbered_file, around: -3)).to be_nil
    end

    it "returns nil rather than raising when the read blows up" do
      path = numbered_file
      allow(File).to receive(:read).and_raise(Errno::EACCES)

      expect(source_file.read(path, around: 1)).to be_nil
    end
  end

  describe "caching" do
    it "reads a given file from disk only once" do
      path = numbered_file
      allow(File).to receive(:read).and_call_original

      3.times { source_file.read(path, around: 5) }

      expect(File).to have_received(:read).once
    end

    it "serves different windows of the same file from one read" do
      path = numbered_file
      allow(File).to receive(:read).and_call_original

      first = source_file.read(path, around: 5, context: 1)
      second = source_file.read(path, around: 30, context: 1)

      expect(first.lines).to eq(["line 4", "line 5", "line 6"])
      expect(second.lines).to eq(["line 29", "line 30", "line 31"])
      expect(File).to have_received(:read).once
    end

    it "re-reads after the file changes" do
      path = write("changing.rb", "before\n")
      expect(source_file.read(path, around: 1).lines).to eq(["before"])

      File.write(path, "after\n")
      File.utime(Time.now + 5, Time.now + 5, path)

      expect(source_file.read(path, around: 1).lines).to eq(["after"])
    end

    it "keeps at most one entry per path" do
      path = write("churn.rb", "one\n")
      source_file.read(path, around: 1)

      5.times do |i|
        File.write(path, "version #{i}\n")
        File.utime(Time.now + i + 1, Time.now + i + 1, path)
        source_file.read(path, around: 1)
      end

      keys = described_class.instance_variable_get(:@cache).keys
      expect(keys.count { |(cached_path, _, _)| cached_path == path }).to eq(1)
    end

    it "is bounded" do
      (described_class::CACHE_LIMIT + 10).times do |i|
        source_file.read(write("many/file_#{i}.rb", "line\n"), around: 1)
      end

      cache = described_class.instance_variable_get(:@cache)
      expect(cache.size).to be <= described_class::CACHE_LIMIT
    end

    it "evicts the least recently used entry" do
      cache = described_class.instance_variable_get(:@cache)
      cache.clear

      paths = Array.new(described_class::CACHE_LIMIT) { |i|
        write("lru/file_#{i}.rb", "line\n")
      }
      paths.each { |path| source_file.read(path, around: 1) }

      # Touch the oldest entry so it is no longer the eviction candidate.
      source_file.read(paths.first, around: 1)
      source_file.read(write("lru/extra.rb", "line\n"), around: 1)

      cached = cache.keys.map(&:first)
      expect(cached).to include(paths.first)
      expect(cached).not_to include(paths[1])
    end
  end
end
