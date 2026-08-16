# frozen_string_literal: true

require "hanami/webconsole/backtrace"
require "fileutils"
require "tmpdir"

RSpec.describe Hanami::Webconsole::Backtrace do
  around do |example|
    Dir.mktmpdir("hanami-webconsole") do |dir|
      @tmpdir = File.realpath(dir)
      example.run
    end
  end

  attr_reader :tmpdir

  def root
    File.join(tmpdir, "app_root")
  end

  def write(path, content = "one\ntwo\nthree\n")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def backtrace_for(exception, bindings: nil)
    described_class.new(exception: exception, root: root, bindings: bindings)
  end

  def exception_with(lines)
    RuntimeError.new("boom").tap { |error| error.set_backtrace(lines) }
  end

  describe "#frames" do
    it "builds a frame per backtrace location, raise point first" do
      exception = begin
        raise ArgumentError, "boom"
      rescue ArgumentError => exception
        exception
      end

      frames = backtrace_for(exception).frames

      expect(frames).to all(be_a(Hanami::Webconsole::Frame))
      expect(frames.first.path).to eq(__FILE__)
      expect(frames.first.lineno).to be_a(Integer)
      expect(frames.length).to eq(exception.backtrace_locations.length)
    end

    it "memoizes" do
      exception = exception_with(["#{root}/app/actions/show.rb:3:in 'Show#handle'"])
      subject = backtrace_for(exception)

      expect(subject.frames).to equal(subject.frames)
    end

    it "is empty when there is no backtrace at all" do
      expect(backtrace_for(RuntimeError.new("boom")).frames).to eq([])
    end

    it "is empty when the backtrace is empty" do
      expect(backtrace_for(exception_with([])).frames).to eq([])
    end
  end

  describe "falling back to backtrace strings" do
    it "parses the Ruby 3.4 label format" do
      path = write(File.join(root, "app/actions/show.rb"))
      exception = exception_with(["#{path}:2:in 'Bookshelf::Actions::Show#handle'"])

      expect(exception.backtrace_locations).to be_nil

      frame = backtrace_for(exception).frames.first

      expect(frame.path).to eq(path)
      expect(frame.lineno).to eq(2)
      expect(frame.label).to eq("Bookshelf::Actions::Show#handle")
      expect(frame.kind).to eq(:app)
    end

    it "parses the pre-3.4 label format" do
      path = write(File.join(root, "app/actions/show.rb"))
      exception = exception_with(["#{path}:2:in `handle'"])

      frame = backtrace_for(exception).frames.first

      expect(frame.lineno).to eq(2)
      expect(frame.label).to eq("handle")
    end

    it "parses block labels" do
      exception = exception_with(["/a/b.rb:9:in 'block (2 levels) in Foo#bar'"])

      expect(backtrace_for(exception).frames.first.label).to eq("block (2 levels) in Foo#bar")
    end

    it "parses a line with no label" do
      exception = exception_with(["/a/b.rb:9"])
      frame = backtrace_for(exception).frames.first

      expect(frame.path).to eq("/a/b.rb")
      expect(frame.lineno).to eq(9)
      expect(frame.label).to eq("")
    end

    it "keeps colons in the path" do
      exception = exception_with(["C:/apps/bookshelf/app.rb:12:in 'Foo#bar'"])
      frame = backtrace_for(exception).frames.first

      expect(frame.path).to eq("C:/apps/bookshelf/app.rb")
      expect(frame.lineno).to eq(12)
    end

    it "parses internal frames" do
      exception = exception_with(["<internal:kernel>:187:in 'Integer#times'"])
      frame = backtrace_for(exception).frames.first

      expect(frame.path).to eq("<internal:kernel>")
      expect(frame.lineno).to eq(187)
      expect(frame.kind).to eq(:core)
    end

    it "keeps an unparseable line verbatim as a core frame" do
      exception = exception_with(["something entirely unexpected"])
      frame = backtrace_for(exception).frames.first

      expect(frame.path).to eq("something entirely unexpected")
      expect(frame.lineno).to eq(0)
      expect(frame.kind).to eq(:core)
    end

    it "skips blank entries" do
      exception = exception_with(["", "/a/b.rb:1:in 'x'"])

      expect(backtrace_for(exception).frames.length).to eq(1)
    end

    it "preserves order" do
      exception = exception_with(["/a/one.rb:1:in 'x'", "/a/two.rb:2:in 'y'"])

      expect(backtrace_for(exception).frames.map(&:lineno)).to eq([1, 2])
    end
  end

  describe "#app_frames" do
    it "selects only the app frames" do
      app = write(File.join(root, "app/actions/show.rb"))
      gem = write(File.join(tmpdir, "gem_home/gems/rack-3.1.8/lib/rack.rb"))
      exception = exception_with(
        ["#{app}:2:in 'Show#handle'", "#{gem}:2:in 'Rack#call'", "<internal:kernel>:1:in 'x'"]
      )

      subject = backtrace_for(exception)

      expect(subject.frames.map(&:kind)).to eq([:app, :gem, :core])
      expect(subject.app_frames.map(&:path)).to eq([app])
    end

    it "is empty when nothing belongs to the app" do
      exception = exception_with(["<internal:kernel>:1:in 'x'"])

      expect(backtrace_for(exception).app_frames).to eq([])
    end
  end

  describe "bindings" do
    def capture_binding
      binding
    end

    it "aligns bindings with frames by index" do
      captured = capture_binding
      exception = exception_with(["/a/one.rb:1:in 'x'", "/a/two.rb:2:in 'y'"])

      frames = backtrace_for(exception, bindings: [nil, captured]).frames

      expect(frames[0].binding).to be_nil
      expect(frames[1].binding).to equal(captured)
    end

    it "tolerates fewer bindings than frames" do
      exception = exception_with(["/a/one.rb:1:in 'x'", "/a/two.rb:2:in 'y'"])

      frames = backtrace_for(exception, bindings: []).frames

      expect(frames.map(&:binding)).to eq([nil, nil])
    end

    it "ignores anything that is not a Binding" do
      exception = exception_with(["/a/one.rb:1:in 'x'"])

      frames = backtrace_for(exception, bindings: ["not a binding"]).frames

      expect(frames.first.binding).to be_nil
    end

    it "ignores a bindings argument that is not an array" do
      exception = exception_with(["/a/one.rb:1:in 'x'"])

      expect(backtrace_for(exception, bindings: :nope).frames.first.binding).to be_nil
    end
  end

  describe "never raising" do
    it "degrades when backtrace_locations raises" do
      exception = exception_with(["/a/one.rb:1:in 'x'"])
      allow(exception).to receive(:backtrace_locations).and_raise("boom")

      expect(backtrace_for(exception).frames.length).to eq(1)
    end

    it "degrades when both backtrace readers raise" do
      hostile = Class.new(StandardError) do
        def backtrace_locations = raise("boom")
        def backtrace = raise("boom")
      end

      expect(backtrace_for(hostile.new).frames).to eq([])
    end

    it "degrades when the backtrace is not an array" do
      exception = RuntimeError.new("boom")
      allow(exception).to receive(:backtrace).and_return("not an array")

      expect(backtrace_for(exception).frames).to eq([])
    end

    it "degrades when the exception answers nothing useful" do
      expect(backtrace_for(Object.new).frames).to eq([])
    end

    it "degrades when the exception is nil" do
      expect(backtrace_for(nil).frames).to eq([])
    end

    it "tolerates a nil root" do
      exception = exception_with(["/a/one.rb:1:in 'x'"])
      subject = described_class.new(exception: exception, root: nil)

      expect(subject.frames.first.kind).to eq(:core)
      expect(subject.app_frames).to eq([])
    end
  end
end
