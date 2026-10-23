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
    # The editor is chosen with `ENV["HANAMI_EDITOR"]`, falling back to `:vscode`. An unknown
    # name falls back to the default rather than raising: a mistyped environment variable must
    # never be the reason an error page fails to render.
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

      # Returns an editor configured from the environment.
      #
      # @return [Editor]
      def self.from_env(env = ENV)
        new(env[ENV_KEY] || DEFAULT)
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

      # Returns the URL scheme, for use in a Content-Security-Policy.
      #
      # @return [String]
      def scheme
        "#{@name}://"
      end

      private

      # Percent-encodes a path for use as a URL path segment, keeping its separators.
      #
      # `URI::DEFAULT_PARSER.escape` would do this, but it is deprecated as of Ruby 3.4.
      def escape_path(path)
        URI.encode_www_form_component(path).gsub("+", "%20").gsub("%2F", "/")
      end

      def canonical_name(name)
        symbol = name.to_s.strip.downcase.to_sym
        symbol = ALIASES.fetch(symbol, symbol)

        TEMPLATES.key?(symbol) ? symbol : DEFAULT
      end
    end
  end
end
