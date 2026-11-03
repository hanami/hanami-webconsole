# frozen_string_literal: true

require_relative "rendering/html"
require_relative "rendering/markdown"
require_relative "rendering/json"

module Hanami
  module Webconsole
    # Renderings of an {ErrorPage}: {HTML}, {Markdown} (for plain text) and {JSON}.
    #
    # Each one takes the page, plus whatever else its format needs, and returns the rendered
    # page from `#to_s`.
    #
    # @api private
    module Rendering
    end
  end
end
