# frozen_string_literal: true

require "hanami/webconsole/frame"
require "fileutils"
require "tmpdir"

RSpec.describe Hanami::Webconsole::Frame do
  # `Inspector` is built in a separate workstream. Frame's contract is that it routes every value
  # through it, so a deterministic stand-in is substituted here — and only here, never in `lib`.
  let(:inspector) {
    Module.new do
      def self.call(object, limit: 2_000)
        "inspected:#{object.inspect}"[0, limit]
      end

      def self.class_name(object)
        "class:#{object.class}"
      end
    end
  }

  before do
    stub_const("Hanami::Webconsole::Inspector", inspector)
  end

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

  def gem_home
    File.join(tmpdir, "gem_home")
  end

  def write(path, content = "one\ntwo\nthree\nfour\nfive\n")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def location(path:, lineno: 3, label: "Bookshelf::Actions::Show#handle")
    Struct.new(:path, :lineno, :label).new(path, lineno, label)
  end

  def frame(path:, lineno: 3, label: "Bookshelf::Actions::Show#handle", binding: nil)
    described_class.new(
      location: location(path: path, lineno: lineno, label: label),
      root: root,
      binding: binding
    )
  end

  describe "attributes" do
    it "exposes path, lineno and label" do
      path = write(File.join(root, "app/actions/show.rb"))
      subject = frame(path: path, lineno: 42, label: "Show#handle")

      expect(subject.path).to eq(path)
      expect(subject.lineno).to eq(42)
      expect(subject.label).to eq("Show#handle")
      expect(subject.root).to eq(root)
    end

    it "prefers absolute_path when the location offers one" do
      path = write(File.join(root, "app/actions/show.rb"))
      location = Struct.new(:path, :absolute_path, :lineno, :label)
        .new("app/actions/show.rb", path, 1, "x")

      subject = described_class.new(location: location, root: root)

      expect(subject.path).to eq(path)
    end

    it "falls back to path when absolute_path is nil" do
      location = Struct.new(:path, :absolute_path, :lineno, :label)
        .new("(eval)", nil, 1, "x")

      expect(described_class.new(location: location, root: root).path).to eq("(eval)")
    end

    it "degrades rather than raising when the location misbehaves" do
      broken = Class.new do
        def path = raise("boom")
        def lineno = raise("boom")
        def label = raise("boom")
      end

      subject = described_class.new(location: broken.new, root: root)

      expect(subject.path).to eq("")
      expect(subject.lineno).to eq(0)
      expect(subject.label).to eq("")
      expect(subject.kind).to eq(:core)
    end
  end

  describe "#kind" do
    it "is :app for a file under the app root" do
      subject = frame(path: write(File.join(root, "app/actions/show.rb")))

      expect(subject.kind).to eq(:app)
      expect(subject).to be_app
    end

    it "is :gem for a vendored dependency under root/vendor" do
      path = write(File.join(root, "vendor/bundle/ruby/3.3.0/gems/rack-3.1.8/lib/rack.rb"))

      subject = frame(path: path)

      expect(subject.kind).to eq(:gem)
      expect(subject).not_to be_app
    end

    it "is :gem for a file inside an installed gem" do
      path = write(File.join(gem_home, "gems/rack-3.1.8/lib/rack/method_override.rb"))

      expect(frame(path: path).kind).to eq(:gem)
    end

    it "is :gem for a file under a Gem.path entry without a gems/ segment" do
      path = write(File.join(gem_home, "extensions/arm64/nokogiri.rb"))
      allow(described_class).to receive(:gem_paths).and_return([gem_home])

      expect(frame(path: path).kind).to eq(:gem)
    end

    it "is :core for internal Ruby frames" do
      expect(frame(path: "<internal:kernel>", lineno: 187).kind).to eq(:core)
    end

    it "is :core for eval'd code" do
      expect(frame(path: "(eval at foo.rb:1)").kind).to eq(:core)
      expect(frame(path: "(irb)").kind).to eq(:core)
    end

    it "is :core for a path that does not exist" do
      expect(frame(path: File.join(root, "app/gone.rb")).kind).to eq(:core)
    end

    it "is :core for an empty path" do
      expect(frame(path: "").kind).to eq(:core)
    end

    it "does not treat a sibling directory sharing the root's prefix as app code" do
      path = write("#{root}-other/app/actions/show.rb")

      expect(frame(path: path).kind).to eq(:core)
    end
  end

  describe "#display_path" do
    it "is relative to the root for app frames" do
      path = write(File.join(root, "app/actions/books/show.rb"))

      expect(frame(path: path).display_path).to eq("app/actions/books/show.rb")
    end

    it "strips everything up to the gems directory for gem frames" do
      path = write(File.join(gem_home, "gems/rack-3.1.8/lib/rack/method_override.rb"))

      expect(frame(path: path).display_path).to eq("rack-3.1.8/lib/rack/method_override.rb")
    end

    it "strips the gem home when there is no gems/ segment" do
      path = write(File.join(gem_home, "extensions/arm64/nokogiri.rb"))
      allow(described_class).to receive(:gem_paths).and_return([gem_home])

      expect(frame(path: path).display_path).to eq("extensions/arm64/nokogiri.rb")
    end

    it "is the raw path for core frames" do
      expect(frame(path: "<internal:kernel>").display_path).to eq("<internal:kernel>")
    end
  end

  describe "#source" do
    it "returns an excerpt around the frame's line" do
      path = write(File.join(root, "app/actions/show.rb"))

      excerpt = frame(path: path, lineno: 3).source

      expect(excerpt.highlight_lineno).to eq(3)
      expect(excerpt.lines).to eq(%w[one two three four five])
    end

    it "is nil when the file cannot be read" do
      expect(frame(path: File.join(root, "gone.rb")).source).to be_nil
      expect(frame(path: "<internal:kernel>").source).to be_nil
    end

    it "memoizes the lookup, including a nil result" do
      subject = frame(path: File.join(root, "gone.rb"))
      allow(Hanami::Webconsole::SourceFile).to receive(:read).and_call_original

      2.times { subject.source }

      expect(Hanami::Webconsole::SourceFile).to have_received(:read).once
    end
  end

  describe "variables without a binding" do
    subject { frame(path: write(File.join(root, "app/actions/show.rb"))) }

    it "returns no locals" do
      expect(subject.locals).to eq([])
    end

    it "returns no instance variables" do
      expect(subject.instance_vars).to eq([])
    end

    it "has no receiver" do
      expect(subject.receiver_inspect).to be_nil
    end

    it "exposes a nil binding" do
      expect(subject.binding).to be_nil
    end
  end

  describe "variables with a binding" do
    let(:receiver) {
      Class.new do
        def initialize
          @title = "Hanami"
          @count = 3
        end

        def capture
          book = "Practical Object-Oriented Design"
          pages = 272
          binding if book && pages
        end
      end
    }

    subject {
      frame(path: write(File.join(root, "app/actions/show.rb")), binding: receiver.new.capture)
    }

    it "builds a Variable for each local" do
      names = subject.locals.map(&:name)

      expect(names).to contain_exactly("book", "pages")
      expect(subject.locals).to all(be_a(Hanami::Webconsole::Variable))
    end

    it "routes local values through Inspector" do
      pages = subject.locals.find { |local| local.name == "pages" }

      expect(pages.value).to eq("inspected:272")
      expect(pages.class_name).to eq("class:Integer")
    end

    it "builds a Variable for each instance variable" do
      names = subject.instance_vars.map(&:name)

      expect(names).to contain_exactly("@title", "@count")
    end

    it "routes instance variable values through Inspector" do
      title = subject.instance_vars.find { |ivar| ivar.name == "@title" }

      expect(title.value).to eq(%(inspected:"Hanami"))
      expect(title.class_name).to eq("class:String")
    end

    it "inspects the receiver" do
      expect(subject.receiver_inspect).to start_with("inspected:")
    end

    it "memoizes locals" do
      expect(subject.locals).to equal(subject.locals)
    end

    it "drops a variable whose inspection blows up, keeping the rest" do
      allow(inspector).to receive(:call).and_call_original
      allow(inspector).to receive(:call).with(272).and_raise("boom")

      expect(subject.locals.map(&:name)).to eq(["book"])
    end

    it "returns an empty array when the whole binding blows up" do
      allow(inspector).to receive(:class_name).and_raise(SystemStackError)

      expect(subject.locals).to eq([])
    end
  end

  describe "a receiver that does not answer #instance_variables" do
    it "degrades to an empty array" do
      hostile = Class.new do
        def instance_variables
          raise NoMethodError, "undefined method 'instance_variables'"
        end

        def capture
          binding
        end
      end

      subject = frame(
        path: write(File.join(root, "app/actions/show.rb")),
        binding: hostile.new.capture
      )

      expect(subject.instance_vars).to eq([])
    end
  end

  describe ".gem_paths" do
    it "includes the RubyGems paths" do
      expect(described_class.gem_paths).to include(*Gem.path.map { |p| p.chomp("/") })
    end

    it "returns absolute directories without trailing separators" do
      expect(described_class.gem_paths).to all(satisfy { |path| !path.end_with?("/") })
    end
  end
end
