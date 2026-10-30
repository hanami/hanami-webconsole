# frozen_string_literal: true

require "tmpdir"

RSpec.describe Hanami::Diagnostics::Registry, :isolate_diagnostics do
  subject(:registry) { described_class }

  let(:context) { Hanami::Diagnostics::Context.new(slice: "Main::Slice") }

  # Returns a new diagnostic class. Its instances keep the exception and context they were built
  # with, so our specs can check what the registry built them for.
  def diagnostic_class(applies: true)
    Class.new do
      attr_reader :exception, :context

      define_method(:initialize) { |exception, context| @exception, @context = exception, context }
      define_method(:applies?) { applies.respond_to?(:call) ? applies.call : applies }
    end
  end

  # Returns the diagnostic the registry finds for the exception, or nil.
  def diagnostic_for(exception, slice: context.slice)
    registry.for(exception, Hanami::Diagnostics::Context.new(slice:))&.diagnostic
  end

  describe ".register" do
    it "rejects anything but an exception class name, and a diagnostic class or its name" do
      expect { registry.register(KeyError, diagnostic_class) }.to raise_error(ArgumentError, /name as a string/)
      expect { registry.register("", diagnostic_class) }.to raise_error(ArgumentError, /name as a string/)
      expect { registry.register("KeyError", "") }.to raise_error(ArgumentError, /diagnostic class or its name/)
      expect { registry.register("KeyError", diagnostic_class.new(nil, nil)) }
        .to raise_error(ArgumentError, /diagnostic class or its name/)
    end

    it "keeps a named diagnostic class by name, and uses the class as it is when an error needs it" do
      original = diagnostic_class
      replacement = diagnostic_class
      stub_const("SpecDiagnostic", original)
      registry.register("KeyError", SpecDiagnostic)
      stub_const("SpecDiagnostic", replacement)

      expect(diagnostic_for(KeyError.new("bad"))).to be_a(replacement)
    end

    it "accepts a diagnostic's name, without needing the class to be loaded yet" do
      loaded_later = diagnostic_class
      registry.register("KeyError", "SpecDiagnostic")
      stub_const("SpecDiagnostic", loaded_later)

      expect(diagnostic_for(KeyError.new("bad"))).to be_a(loaded_later)
    end

    it "skips a diagnostic whose name can't be looked up, with a warning" do
      fallback = diagnostic_class
      registry.register("KeyError", fallback)
      registry.register("KeyError", "NoSuchDiagnostic")

      expect { registry.for(KeyError.new("bad"), context) }
        .to output(/skipped the diagnostic NoSuchDiagnostic, which raised NameError/).to_stderr

      expect(diagnostic_for(KeyError.new("bad"))).to be_a(fallback)
    end

    it "warns only once about a name that can't be looked up" do
      registry.register("KeyError", diagnostic_class)
      registry.register("KeyError", "NoSuchDiagnostic")

      expect { registry.for(KeyError.new("bad"), context) }.to output(/NoSuchDiagnostic/).to_stderr
      expect { registry.for(KeyError.new("bad"), context) }.not_to output.to_stderr
    end

    it "doesn't look up diagnostics after the one that applies" do
      key = diagnostic_class
      registry.register("StandardError", "NoSuchDiagnostic")
      registry.register("KeyError", key)

      expect { registry.for(KeyError.new("bad"), context) }.not_to output.to_stderr
      expect(diagnostic_for(KeyError.new("bad"))).to be_a(key)
    end

    it "tries the most recently registered diagnostic first" do
      first = diagnostic_class
      second = diagnostic_class
      registry.register("KeyError", first)
      registry.register("KeyError", second)

      expect(diagnostic_for(KeyError.new("bad"))).to be_a(second)
    end

    it "falls back to an earlier diagnostic that applies" do
      first = diagnostic_class
      second = diagnostic_class(applies: false)
      registry.register("KeyError", first)
      registry.register("KeyError", second)

      expect(diagnostic_for(KeyError.new("bad"))).to be_a(first)
    end
  end

  describe "loading diagnostics files" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname(dir)
        example.run
      end
    end

    before do
      @gems = {}
      allow(Gem).to receive(:loaded_specs).and_return(@gems)
    end

    # Writes a diagnostics file that registers a new diagnostic class, and returns that class.
    #
    # The class is stubbed as a constant, so the file can refer to it by name. Each load of the file
    # registers the class again, so loading a file twice into the same registrations would add a
    # second entry.
    def write_diagnostic(relative_path, body = nil)
      diagnostic = diagnostic_class
      name = "FileDiagnostic#{diagnostic.object_id}"
      stub_const(name, diagnostic)

      path = @dir.join(relative_path)
      path.dirname.mkpath
      path.write(body || <<~RUBY)
        Hanami::Diagnostics.register("KeyError", #{name})
      RUBY

      diagnostic
    end

    # Bundles a fake gem at `gems/<name>`, with the given `hanami_diagnostics` metadata.
    def bundle(name, diagnostics = nil)
      metadata = diagnostics ? {"hanami_diagnostics" => diagnostics} : {}
      @gems[name] = double("Gem::Specification", name:, metadata:, full_gem_path: @dir.join("gems", name).to_s)
    end

    describe ".load_gem_files" do
      it "loads the file given by each gem's hanami_diagnostics metadata, into the process-wide registry" do
        somegem = write_diagnostic("gems/somegem/lib/somegem/diagnostics.rb")
        bundle("somegem", "lib/somegem/diagnostics.rb")
        bundle("othergem")

        registry.load_gem_files

        expect(diagnostic_for(KeyError.new("bad"))).to be_a(somegem)
      end

      it "loads gems in order of name, so the last by name is tried first" do
        write_diagnostic("gems/a-gem/diagnostics.rb")
        b_gem = write_diagnostic("gems/b-gem/diagnostics.rb")
        bundle("b-gem", "diagnostics.rb")
        bundle("a-gem", "diagnostics.rb")

        registry.load_gem_files

        expect(diagnostic_for(KeyError.new("bad"))).to be_a(b_gem)
      end

      it "skips a file that raises, or is missing, with a warning, and loads the rest" do
        write_diagnostic("gems/broken/diagnostics.rb", "def broken(")
        working = write_diagnostic("gems/working/diagnostics.rb")
        bundle("broken", "diagnostics.rb")
        bundle("missing", "diagnostics.rb")
        bundle("working", "diagnostics.rb")

        expect { registry.load_gem_files }
          .to output(
            a_string_including(
              "gems/broken/diagnostics.rb, which raised SyntaxError",
              "gems/missing/diagnostics.rb, which raised LoadError"
            )
          ).to_stderr

        expect(diagnostic_for(KeyError.new("bad"))).to be_a(working)
      end
    end

    describe "the app's and slices' files" do
      def slice_double(root, slices: [])
        app = double("App", root:)
        allow(app).to receive(:with_slices).and_return([*slices, app])
        double("Slice", app:)
      end

      let(:app_slice) { slice_double(@dir.join("app")) }

      it "loads them the first time it looks up a diagnostic for the app" do
        app = write_diagnostic("app/config/diagnostics.rb")

        expect(registry.entries).not_to include("KeyError")
        expect(diagnostic_for(KeyError.new("bad"), slice: app_slice)).to be_a(app)
        expect(registry.entries).to include("KeyError")
      end

      it "loads the app's file, then each slice's, so a slice's are tried first" do
        write_diagnostic("app/config/diagnostics.rb")
        admin = write_diagnostic("slices/admin/config/diagnostics.rb")
        admin_slice = double("Admin::Slice", root: @dir.join("slices/admin"))

        slice = slice_double(@dir.join("app"), slices: [admin_slice])

        expect(diagnostic_for(KeyError.new("bad"), slice:)).to be_a(admin)
      end

      it "loads them after gems' files, so they're tried first" do
        write_diagnostic("gems/somegem/diagnostics.rb")
        app = write_diagnostic("app/config/diagnostics.rb")
        bundle("somegem", "diagnostics.rb")
        registry.load_gem_files

        expect(diagnostic_for(KeyError.new("bad"), slice: app_slice)).to be_a(app)
      end

      it "loads them once for each app, so edits to them need a restart" do
        app = write_diagnostic("app/config/diagnostics.rb")
        slice = app_slice
        diagnostic_for(KeyError.new("bad"), slice:)

        write_diagnostic("app/config/diagnostics.rb")

        expect(diagnostic_for(KeyError.new("bad"), slice:)).to be_a(app)
        expect(registry.entries["KeyError"].length).to eq(1)
      end

      it "doesn't warn about Hanami::Diagnostics.register from a diagnostics file" do
        write_diagnostic("gems/somegem/diagnostics.rb")
        write_diagnostic("app/config/diagnostics.rb")
        bundle("somegem", "diagnostics.rb")

        expect {
          registry.load_gem_files
          diagnostic_for(KeyError.new("bad"), slice: app_slice)
        }.not_to output.to_stderr
      end
    end
  end

  describe "Hanami::Diagnostics.register" do
    it "warns when called from outside a diagnostics file, naming where, but still registers" do
      key = diagnostic_class

      expect { Hanami::Diagnostics.register("KeyError", key) }
        .to output(/#{Regexp.escape(__FILE__)}:\d+.*call Hanami::Diagnostics.register only from config\/diagnostics.rb/)
        .to_stderr

      expect(diagnostic_for(KeyError.new("bad"))).to be_a(key)
    end
  end

  describe ".for" do
    def error_with_cause(outer, cause)
      raise cause
    rescue cause.class
      begin
        raise outer
      rescue outer.class => error
        error
      end
    end

    it "is nil when nothing matches" do
      expect(diagnostic_for(RuntimeError.new("boom"))).to be_nil
    end

    it "builds the diagnostic with the exception and the context" do
      registry.register("RuntimeError", diagnostic_class)
      error = RuntimeError.new("boom")

      expect(diagnostic_for(error)).to have_attributes(exception: error, context:)
    end

    it "covers subclasses of a registered class" do
      standard = diagnostic_class
      registry.register("StandardError", standard)

      expect(diagnostic_for(ArgumentError.new("bad"))).to be_a(standard)
    end

    it "prefers the closest ancestor" do
      argument = diagnostic_class
      registry.register("StandardError", diagnostic_class)
      registry.register("ArgumentError", argument)

      expect(diagnostic_for(ArgumentError.new("bad"))).to be_a(argument)
    end

    it "walks the cause chain, for an error that wraps another" do
      key = diagnostic_class
      cause = KeyError.new("inner")
      registry.register("KeyError", key)

      expect(diagnostic_for(error_with_cause(RuntimeError.new("outer"), cause)))
        .to be_a(key).and have_attributes(exception: cause)
    end

    it "prefers the outer error to its cause" do
      runtime = diagnostic_class
      registry.register("RuntimeError", runtime)
      registry.register("KeyError", diagnostic_class)

      expect(diagnostic_for(error_with_cause(RuntimeError.new("outer"), KeyError.new("inner")))).to be_a(runtime)
    end

    it "prefers the outer error even to a more specific match on its cause" do
      standard = diagnostic_class
      outer = RuntimeError.new("outer")
      registry.register("StandardError", standard)
      registry.register("KeyError", diagnostic_class)

      expect(diagnostic_for(error_with_cause(outer, KeyError.new("inner"))))
        .to be_a(standard).and have_attributes(exception: outer)
    end

    it "skips a diagnostic that doesn't apply, so it can't block a more specific one" do
      key = diagnostic_class
      registry.register("StandardError", diagnostic_class(applies: false))
      registry.register("KeyError", key)

      expect(diagnostic_for(error_with_cause(RuntimeError.new("outer"), KeyError.new("inner")))).to be_a(key)
    end

    it "skips a diagnostic whose `applies?` raises" do
      standard = diagnostic_class
      registry.register("RuntimeError", diagnostic_class(applies: -> { raise "broken" }))
      registry.register("StandardError", standard)

      expect(diagnostic_for(RuntimeError.new("boom"))).to be_a(standard)
    end

    it "skips a diagnostic that fails to build" do
      standard = diagnostic_class
      registry.register("RuntimeError", Class.new { def initialize(*) = raise("broken") })
      registry.register("StandardError", standard)

      expect(diagnostic_for(RuntimeError.new("boom"))).to be_a(standard)
    end

    it "ignores anonymous classes in the ancestors" do
      runtime = diagnostic_class
      registry.register("RuntimeError", runtime)

      expect(diagnostic_for(Class.new(RuntimeError).new("anon"))).to be_a(runtime)
    end
  end
end
