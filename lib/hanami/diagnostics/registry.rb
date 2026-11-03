# frozen_string_literal: true

module Hanami
  module Diagnostics
    # The registered diagnostics and the lookup that finds the diagnostic for an exception.
    #
    # A diagnostic is a plain class, built with an exception and a {Context}. Every method is
    # optional:
    #
    # - `applies?`: whether the diagnostic applies to this exception. A diagnostic is only built for
    #   exceptions of its registered class (or a subclass), so this can check the details on the
    #   exception instance itself. If false, the diagnostic is skipped and the next matching one is
    #   tried. Defaults to true.
    # - `title`: a short name for the situation, shown in place of the exception class name. This is
    #   plain text on a single line. The exception message is always shown below it, so don't
    #   restate the message.
    # - `explanation`: text explaining why the exception was raised, shown after the exception
    #   message, as text or an array of parts. Use it only for what the message doesn't already say,
    #   such as a cause the diagnostic found by checking the app.
    # - `fix`: instructions on how to fix it, as text, an array of parts, or
    #   `{name:, text:, destructive:}`.
    # - `run_fix`: performs a runnable fix when the developer clicks its button on the page. The
    #   button only appears when `fix` returns a fix with some text. If `run_fix` returns a string,
    #   the page shows it as the fix's output. If it raises, the page shows the fix as failed, with
    #   the error.
    # - `dataset`: evidence from app state, as `{title:, columns:, rows:}`.
    #
    # The explanation and fix use a small subset of Markdown (see {Text}). They can also be given as
    # an array of parts: strings for paragraphs, arrays for lists, and hashes such as `{sh: "..."}`
    # for code (see {Text.join}). The exception message is shown exactly as written, the same as in
    # a terminal. If you control the exception class, write a good message
    # there first. Use a diagnostic only for the things an exception message can't provide on its
    # own: details from the running app, or a runnable fix.
    #
    # Diagnostics are kept separate from the errors they describe, so error classes carry no
    # development-specific code into production. For now, there is no base class and no DSL, so a
    # diagnostic needs nothing from Hanami Webconsole.
    #
    # Gems, apps and slices register their diagnostics with {Hanami::Diagnostics.register}, in files
    # that only webconsole loads: a gem's file is named by its `hanami_diagnostics` gemspec metadata
    # (see {.load_gem_files}), and an app's or slice's is `config/diagnostics.rb` (see {.for}).
    #
    # **The diagnostic contract is currently experimental.**
    #
    # @api private
    module Registry
      # The gemspec metadata key that gives the path of a gem's diagnostics file, relative to the
      # gem's root. For example:
      #
      #   spec.metadata["hanami_diagnostics"] = "lib/rom/diagnostics.rb"
      #
      # Reading the metadata of every bundled gem takes well under 1ms, and can't find a file by
      # accident, unlike searching every gem's files.
      GEM_METADATA_KEY = "hanami_diagnostics"

      # Where an app or a slice puts its diagnostics, relative to its root.
      SLICE_FILE = "config/diagnostics.rb"

      # The thread-local key that's set while a diagnostics file is loading.
      LOADING_KEY = :__hanami_diagnostics_loading

      # The registered diagnostics.
      @entries = {}

      # The apps whose diagnostics files have been loaded.
      @loaded_apps = Set.new

      # Lock held while loading an app's diagnostics files, so two error pages built at once can't
      # both load them.
      @load_lock = Mutex.new

      # The diagnostic names that have failed to look up, and have been warned about.
      @warned_entries = Set.new

      class << self
        # Returns the registered diagnostics, keyed by exception class name.
        #
        # Each key has its diagnostics in the order they're tried: the most recently registered
        # first. A diagnostic is kept as its class name, or as the class itself if it has no name.
        #
        # This is exposed so that specs can save and restore the entries around their examples.
        # {.register} never changes an array in place, so a shallow copy is enough.
        #
        # @return [Hash{String => Array<String, Class>}]
        attr_reader :entries

        # Registers a diagnostic for the exception class with the given name.
        #
        # Diagnostics files call this through {Hanami::Diagnostics.register}. Webconsole calls it
        # directly for its own diagnostics.
        #
        # The diagnostic is kept by name, and looked up when an error needs it. So a gem can
        # register a diagnostic without loading it, and an app's diagnostic is always the class as
        # it is now, including after a code reload. A class with no name is kept as it is.
        #
        # @param exception_class_name [String]
        # @param diagnostic [String, Class] the diagnostic class, or its name
        #
        # @return [void]
        #
        # @raise [ArgumentError] if the name isn't a non-empty string, or the diagnostic isn't a
        #   class or a non-empty string
        def register(exception_class_name, diagnostic)
          unless name?(exception_class_name)
            raise ArgumentError, "Give the exception class's name as a string, not #{exception_class_name.inspect}"
          end

          unless name?(diagnostic) || diagnostic.is_a?(Class)
            raise ArgumentError, "Give a diagnostic class or its name, not #{diagnostic.inspect}"
          end

          entry = diagnostic.is_a?(Class) ? diagnostic.name || diagnostic : diagnostic
          @entries[exception_class_name] = [entry, *@entries[exception_class_name]]
          nil
        end

        # Loads the gems' diagnostics files.
        #
        # Each gem names its file in its `hanami_diagnostics` gemspec metadata (see
        # {GEM_METADATA_KEY}). Gems load in order of name. In a bundled app, these are all the gems
        # in the bundle, whether the app requires them or not, so a gem's file should register by
        # class name, and not require the rest of the gem.
        #
        # This runs once, when webconsole is required.
        #
        # @return [void]
        def load_gem_files
          load_files(gem_files)
        end

        # Returns true while a diagnostics file is loading in this thread.
        #
        # @return [Boolean]
        def loading_file?
          !!Thread.current[LOADING_KEY]
        end

        # Returns the diagnostic for the given exception, wrapped and ready to use, or nil if no
        # diagnostic applies.
        #
        # The first time this is called for an app, it loads the diagnostics files of the app and
        # its slices: the app's `config/diagnostics.rb`, then each slice's, parent slices before
        # nested ones. These load after the gems' files, so their diagnostics are tried first, and a
        # slice's before the app's. Every registration is app-wide, including a slice's: there's no
        # way to tell which slice raised an error.
        #
        # Then it looks for a diagnostic registered for the exception's class or any of its
        # ancestors. If none applies, it does the same for each of the exception's causes, starting
        # from the outermost.
        #
        # The first diagnostic that applies is used. Diagnostics that don't apply (or that raise an
        # error when built) are skipped.
        #
        # Since the exception comes before its causes, a diagnostic registered for a broad class
        # (such as `StandardError`) is tried before a more specific one on a cause. To step aside
        # for the more specific one, a broad diagnostic should return false from `applies?` when it
        # has nothing useful to say.
        #
        # @param exception [Exception]
        # @param context [Context]
        #
        # @return [Wrapper, nil]
        def for(exception, context)
          load_app_files(context.slice)

          errors(exception).each do |error|
            entries_for(error).each do |entry|
              next unless (diagnostic_class = resolve(entry))

              diagnostic = Wrapper.build(diagnostic_class, error, context)
              return diagnostic if diagnostic
            end
          end

          nil
        end

        private

        # @return [Boolean]
        def name?(value)
          value.is_a?(String) && !value.empty?
        end

        # Loads the diagnostics files of the given slice's app and its slices, unless they've been
        # loaded already.
        #
        # @param slice [Hanami::Slice, nil]
        #
        # @return [void]
        def load_app_files(slice)
          app = slice.app

          @load_lock.synchronize do
            next unless @loaded_apps.add?(app)

            load_files(
              app.with_slices.reverse
                .map { |slice| slice.root.join(SLICE_FILE).to_s }
                .select { |path| File.file?(path) }
            )
          end
        rescue *ERRORS
          nil
        end

        # Loads the given files.
        #
        # A file that raises an error is skipped with a warning, so a broken diagnostic can't stop
        # the app from booting. Anything it registered before the error stays registered.
        #
        # @param paths [Array<String>]
        #
        # @return [void]
        def load_files(paths)
          Thread.current[LOADING_KEY] = true

          paths.each do |path|
            load(path)
          rescue *ERRORS => exception
            warn "hanami-webconsole: skipped the rest of #{path}, " \
                 "which raised #{exception.class}: #{exception.message}"
          end

          nil
        ensure
          Thread.current[LOADING_KEY] = nil
        end

        # Returns the diagnostics files of the loaded gems, in order of gem name.
        #
        # @return [Array<String>]
        def gem_files
          Gem.loaded_specs.values.sort_by(&:name).filter_map { |spec|
            path = spec.metadata[GEM_METADATA_KEY]
            File.expand_path(path, spec.full_gem_path) if path
          }
        rescue *ERRORS
          []
        end

        # Returns the given exception followed by its causes, from outermost to innermost.
        #
        # @param exception [Exception]
        #
        # @return [Array<Exception>]
        def errors(exception)
          [exception, *Causes.of(exception)]
        end

        # Returns the diagnostics registered for the given error's class and its ancestors, with the
        # closest class first, and the most recently registered diagnostic first for each.
        #
        # These are the entries as registered, which are mostly names. They're looked up with
        # {#resolve} only as they're tried.
        #
        # Anonymous exception classes are skipped, since diagnostics are registered by exception
        # class name.
        #
        # @param error [Exception]
        #
        # @return [Array<String, Class>]
        def entries_for(error)
          error.class.ancestors.flat_map { |ancestor| ancestor.name ? @entries.fetch(ancestor.name, []) : [] }
        rescue StandardError
          []
        end

        # Returns the diagnostic class for an entry, looking it up if it's a name.
        #
        # A name that can't be looked up is skipped. The first time this happens for a name, it
        # warns, so a broken name doesn't print the same warning on every error page.
        #
        # @param entry [String, Class]
        #
        # @return [Class, nil]
        def resolve(entry)
          entry.is_a?(String) ? Object.const_get(entry) : entry
        rescue *ERRORS => exception
          if @warned_entries.add?(entry)
            warn "hanami-webconsole: skipped the diagnostic #{entry}, " \
                 "which raised #{exception.class}: #{exception.message}"
          end
          nil
        end
      end
    end
  end
end
