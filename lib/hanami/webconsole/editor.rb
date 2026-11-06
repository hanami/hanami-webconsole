# frozen_string_literal: true

require "uri"

module Hanami
  module Webconsole
    # Builds "open this file in my editor" deep links for the error page.
    #
    # Editors expose a URL scheme that the operating system hands back to them. There are two
    # shapes in the wild: a path baked into the URL (`vscode://file/<path>:<line>`) and a
    # `file://` URL passed as a query parameter (`txmt://open?url=...&line=...`). Both are
    # supported here; anything else is out of scope until someone asks for it.
    #
    # The editor is chosen with `ENV["HANAMI_EDITOR"]`. Without it, the editor is taken from the
    # command in `ENV["VISUAL"]` or `ENV["EDITOR"]` (so `EDITOR="code -w"` gives VS Code), and
    # otherwise it's `:vscode`. An unknown name falls back to the default rather than raising: a
    # mistyped environment variable must never be the reason an error page fails to render.
    #
    # @api private
    class Editor
      # URL templates, keyed by canonical editor name.
      #
      # `%{path}` keeps its slashes (it is a path segment), `%{escaped_path}` is form-encoded
      # (it is a query parameter value).
      TEMPLATES = {
        vscode: "vscode://file/%{path}:%{line}",
        vscodium: "vscodium://file/%{path}:%{line}",
        cursor: "cursor://file/%{path}:%{line}",
        # Zed takes everything after `zed://file` as the path, so there's no slash before it.
        zed: "zed://file%{path}:%{line}",
        subl: "subl://open?url=file://%{escaped_path}&line=%{line}",
        txmt: "txmt://open?url=file://%{escaped_path}&line=%{line}"
      }.freeze

      # Aliases for the names above, so that both `code` and `vscode` work.
      ALIASES = {
        code: :vscode,
        codium: :vscodium,
        sublime: :subl,
        st: :subl,
        textmate: :txmt,
        tm: :txmt,
        mate: :txmt
      }.freeze

      DEFAULT = :vscode

      # Environment variable naming the editor to link to.
      ENV_KEY = "HANAMI_EDITOR"

      # Environment variables holding the developer's editor command, tried in order when
      # {ENV_KEY} isn't set.
      COMMAND_ENV_KEYS = ["VISUAL", "EDITOR"].freeze

      # Returns an editor configured from the environment.
      #
      # @return [Editor]
      def self.from_env(env = ENV)
        new(env[ENV_KEY] || command_name(env) || DEFAULT)
      end

      # Returns the name of the first editor command in `VISUAL` or `EDITOR` that we can link to,
      # e.g. `"code"` for `"/usr/local/bin/code -w"`, or nil if there's none. An editor without a
      # URL scheme, such as `vim`, is skipped.
      #
      # @return [String, nil]
      def self.command_name(env)
        COMMAND_ENV_KEYS
          .filter_map { |key| env[key].to_s.split.first }
          .map { |command| File.basename(command) }
          .find { |name| canonical_name(name) }
      end
      private_class_method :command_name

      # Returns the canonical name for an editor name or alias, e.g. `:vscode` for `"code"`.
      #
      # @return [Symbol, nil] nil if we don't know the editor
      def self.canonical_name(name)
        symbol = name.to_s.strip.downcase.to_sym
        symbol = ALIASES.fetch(symbol, symbol)

        symbol if TEMPLATES.key?(symbol)
      end

      # @return [Symbol] the canonical editor name
      attr_reader :name

      def initialize(name = DEFAULT)
        @name = canonical_name(name)
        @template = TEMPLATES.fetch(@name)
      end

      # Returns a deep link opening the given file at the given line.
      #
      # @param path [String] an absolute path
      # @param line [Integer, nil]
      #
      # @return [String]
      def url(path, line = 1)
        format(
          @template,
          path: escape_path(path.to_s),
          escaped_path: URI.encode_www_form_component(path.to_s),
          line: line.to_i
        )
      end

      private

      # Percent-encodes a path for use as a URL path segment, keeping its separators.
      #
      # `URI::DEFAULT_PARSER.escape` would do this, but it is deprecated as of Ruby 3.4.
      def escape_path(path)
        URI.encode_www_form_component(path).gsub("+", "%20").gsub("%2F", "/")
      end

      def canonical_name(name)
        self.class.canonical_name(name) || DEFAULT
      end
    end
  end
end
