# frozen_string_literal: true

module Hanami
  module Webconsole
    # Error page fonts are Instrument Sans and Maple Mono NL.
    #
    # Both are under the SIL Open Font License. Fonts are subset to Latin and served by the
    # middleware, under {MOUNT_PATH}, so the browser can cache them.
    #
    # @api private
    module Fonts
      DIR = File.expand_path("fonts", __dir__)

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

      # Returns the `@font-face` rules for every font, loading from the given path. Restricted to
      # the values in `FACES`.
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
