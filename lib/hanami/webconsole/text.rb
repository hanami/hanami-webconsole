# frozen_string_literal: true

module Hanami
  module Webconsole
    # Parses error text and prepares it for formatted display on a web page.
    #
    # Uses a subset of Markdown that looks entirely natural as plain text. This allows for parsing
    # of both diagnostic text as well as exception messages themselves, which need to display in
    # logs and other text-centric places.
    #
    # Parses the following:
    #
    # - a blank line between paragraphs (a single line break is kept as a line break);
    # - lines starting with `- ` for lists;
    # - fenced code blocks, with an optional language (`sh` for a shell command);
    # - a paragraph whose lines are all indented by four spaces (or a tab), as a code block.
    #
    # There is no emphasis, links, headings or tables, so a `*` or `_` in a message we don't own
    # never turns into formatting by mistake. Inline code is handled when rendering, since it works
    # on escaped text (see {Renderer::Scope#inline_html}).
    #
    # @api private
    module Text
      Block = Struct.new(:type, :lines, :language, keyword_init: true)

      FENCE_OPEN = /\A\s*```\s*([\w+-]*)\s*\z/
      FENCE_CLOSE = /\A\s*```\s*\z/
      LIST_ITEM = /\A\s*- (.*)\z/
      INDENTED = /\A(?: {4}|\t)/

      # Languages that mark a code block as shell commands.
      SHELL_LANGUAGES = %w[sh shell bash console].freeze

      class << self
        # @param text [String, nil]
        #
        # @return [Array<Block>] paragraphs, lists and code blocks, in order
        def blocks(text)
          lines = text.to_s.gsub(/\r\n?/, "\n").split("\n")
          blocks = []
          chunk = []

          until lines.empty?
            line = lines.shift

            if (fence = FENCE_OPEN.match(line))
              blocks.concat(chunk_blocks(chunk))
              chunk = []
              blocks << fenced_block(fence[1], lines)
            elsif line.strip.empty?
              blocks.concat(chunk_blocks(chunk))
              chunk = []
            else
              chunk << line
            end
          end

          blocks.concat(chunk_blocks(chunk))
        end

        # @return [Boolean]
        def shell?(block)
          block.type == :code && SHELL_LANGUAGES.include?(block.language)
        end

        private

        # Takes the lines up to the closing fence (or to the end, if there is none).
        def fenced_block(language, lines)
          body = []
          body << lines.shift until lines.empty? || FENCE_CLOSE.match?(lines.first)
          lines.shift

          language = language.downcase
          Block.new(type: :code, lines: dedent(body), language: language.empty? ? nil : language)
        end

        # Splits a run of non-blank lines into paragraphs and lists.
        #
        # A list can follow a paragraph line without a blank line between them ("Paths:" then
        # "- a"), since messages are often written that way.
        def chunk_blocks(lines)
          return [] if lines.empty?

          if lines.all? { |line| INDENTED.match?(line) }
            return [Block.new(type: :code, lines: dedent(lines), language: nil)]
          end

          lines.each_with_object([]) { |line, blocks| add_line(blocks, line) }
        end

        # An indented line after a list item continues that item.
        def add_line(blocks, line)
          last = blocks.last
          item = LIST_ITEM.match(line)

          if !item && last&.type == :list && line.start_with?(" ", "\t")
            last.lines[-1] = "#{last.lines[-1]} #{line.strip}"
            return
          end

          type = item ? :list : :paragraph
          blocks << (last = Block.new(type:, lines: [])) unless last&.type == type
          last.lines << (item ? item[1] : line)
        end

        def dedent(lines)
          indent = lines.reject { |line| line.strip.empty? }.map { |line| line[/\A[ \t]*/].length }.min || 0
          lines.map { |line| line[indent..] || "" }
        end
      end
    end
  end
end
