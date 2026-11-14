# frozen_string_literal: true

module Hanami
  module Webconsole
    # The fonts the error page ships with: Instrument Sans and Maple Mono NL.
    #
    # Both are under the SIL Open Font License, whose text is alongside them in `fonts/`. They are
    # subset to Latin and served by the middleware, under {MOUNT_PATH}, so the browser caches them
    # once rather than downloading them inside every error page.
    #
    # @api private
    module Fonts
      DIR = File.expand_path("fonts", __dir__)

      # Each file the middleware serves, with the `@font-face` descriptors that use it. Only these
      # names are served, so a request can never reach any other file.
      FACES = {
        "instrument-sans.woff2" => {family: "Instrument Sans", weight: "400 700", style: "normal"},
        "maple-mono-nl-regular.woff2" => {family: "Maple Mono NL", weight: "400", style: "normal"},
        "maple-mono-nl-medium.woff2" => {family: "Maple Mono NL", weight: "500", style: "normal"},
        "maple-mono-nl-bold.woff2" => {family: "Maple Mono NL", weight: "700", style: "normal"},
        "maple-mono-nl-italic.woff2" => {family: "Maple Mono NL", weight: "400", style: "italic"}
      }.freeze

      # The URL path the fonts are served from.
      PATH = "#{MOUNT_PATH}/fonts".freeze

      # Returns the font's bytes, or nil if it isn't one of {FACES}.
      #
      # @param name [String]
      #
      # @return [String, nil]
      def self.read(name)
        return unless FACES.key?(name)

        (@cache ||= {})[name] ||= File.binread(File.join(DIR, name)).freeze
      end

      # Returns the `@font-face` rules for every font, loading from the given path.
      #
      # The URLs carry the gem's version, since the fonts are served as immutable: an upgrade that
      # changes them gets new URLs, rather than a year of stale cache.
      #
      # @param path [String] where the fonts are served from: {PATH}, or a relative path for a
      #   page opened from disk
      #
      # @return [String]
      def self.css(path = PATH)
        FACES.map { |name, face|
          <<~CSS
            @font-face {
              font-family: "#{face[:family]}";
              src: url("#{path}/#{name}?v=#{VERSION}") format("woff2");
              font-weight: #{face[:weight]};
              font-style: #{face[:style]};
              font-display: swap;
            }
          CSS
        }.join
      end
    end
  end
end
