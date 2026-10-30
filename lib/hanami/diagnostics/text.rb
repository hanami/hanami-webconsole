# frozen_string_literal: true

module Hanami
  module Diagnostics
    # The text format for diagnostics, and a parser for it.
    #
    # Diagnostics use this format for their title, explanation and fix. It's a subset of Markdown
    # that looks natural as plain text, since diagnostics are also read as text (such as in the
    # error's Markdown output).
    #
    # Exception messages are not parsed. They are shown exactly as written, the same as in a
    # terminal, since most aren't written for any format, and their layout (such as the carets
    # under a syntax error) only makes sense as it is.
    #
    # Parses the following:
    #
    # - a blank line between paragraphs (a single line break is kept as a line break);
    # - lines starting with `- ` for lists;
    # - fenced code blocks, with an optional language (`sh` for a shell command);
    # - a paragraph whose lines are all indented by four spaces (or a tab), as a code block.
    #
    # Backticks mark inline code. These are part of the format, but each consumer handles them as it
    # renders, since that depends on how the text is escaped (see
    # {Webconsole::Rendering::HTML#inline_html}).
    #
    # There is no emphasis, links, headings or tables, so a `*` or `_` (as in a name interpolated
    # into a diagnostic) never turns into formatting by mistake.
    #
    # A fence with no closing fence is text, so a stray fence can't hide the rest of the text. The
    # parser never removes text, except for list markers and the fences around code blocks.
    #
    # This only parses. Rendering the blocks is up to each consumer.
    #
    # @api private
    module Text
      # A block of parsed text: a paragraph, a list or a code block.
      #
      # @!attribute [r] type
      #   @return [Symbol] `:paragraph`, `:list` or `:code`
      # @!attribute [r] lines
      #   @return [Array<String>] the paragraph's lines, the list's items, or the code's lines. A
      #     list item that continues over more than one line has a line break in it.
      # @!attribute [r] language
      #   @return [String, nil] the language of a fenced code block, if it gives one
      Block = Struct.new(:type, :lines, :language, keyword_init: true)

      # Matches the line opening a fenced code block, capturing its backticks and language, if any.
      #
      # Any text after the language is ignored, as in Markdown.
      FENCE_OPEN = /\A\s*(`{3,})\s*([^`\s]*)[^`]*\z/

      # Matches a line that can close a fenced code block, capturing its backticks.
      FENCE_CLOSE = /\A\s*(`{3,})\s*\z/

      # Matches a list item, capturing its text.
      LIST_ITEM = /\A\s*- (.*)\z/

      # Matches a line indented enough to be part of a code block.
      INDENTED = /\A(?: {4}|\t)/

      # The languages that mark a code block as shell commands.
      SHELL_LANGUAGES = %w[sh shell bash console].freeze

      class << self
        # Parses the given text into blocks.
        #
        # Fenced code blocks are read first, so their contents are kept exactly as written. Outside
        # of these, the text is split into chunks at each blank line, and each chunk becomes one or
        # more paragraphs, lists or code blocks.
        #
        # @param text [String, nil]
        #
        # @return [Array<Block>] the blocks, in order
        def blocks(text)
          lines = text.to_s.gsub(/\r\n?/, "\n").split("\n")
          blocks = []
          chunk = []
          index = 0

          while index < lines.length
            line = lines[index]
            fence = FENCE_OPEN.match(line)
            close = fence && closing_fence(lines, index, fence[1])

            if close
              add_chunk(blocks, chunk)
              chunk = []
              blocks << fenced_block(fence[2], lines[(index + 1)...close])
              index = close
            elsif line.strip.empty? && !code_continues?(chunk, lines, index)
              add_chunk(blocks, chunk)
              chunk = []
            else
              chunk << line
            end

            index += 1
          end

          add_chunk(blocks, chunk)
          blocks
        end

        # Returns the fence needed to close the code block left open at the end of the given text,
        # or nil if every code block is closed.
        #
        # This helps to close a code block when text is cut short.
        #
        # @param text [String, nil]
        #
        # @return [String, nil]
        def unclosed_fence(text)
          text.to_s.split("\n").reduce(nil) { |open, line|
            if open
              close = FENCE_CLOSE.match(line)
              close && close[1].length >= open.length ? nil : open
            else
              FENCE_OPEN.match(line)&.[](1)
            end
          }
        end

        # Returns true if the given block is a code block of shell commands.
        #
        # The page shows these as commands to copy, with a `$` prompt.
        #
        # @param block [Block]
        #
        # @return [Boolean]
        def shell?(block)
          block.type == :code && SHELL_LANGUAGES.include?(block.language)
        end

        private

        # Returns the index of the line that closes the fence opened at the given index, or nil if
        # there is none.
        #
        # As in Markdown, the closing fence must have at least as many backticks as the opening one.
        #
        # @param lines [Array<String>]
        # @param index [Integer] the index of the opening fence
        # @param backticks [String] the opening fence's backticks
        #
        # @return [Integer, nil]
        def closing_fence(lines, index, backticks)
          ((index + 1)...lines.length).find { |i|
            close = FENCE_CLOSE.match(lines[i])
            close && close[1].length >= backticks.length
          }
        end

        # Returns a fenced code block.
        #
        # @param language [String] the first word after the opening fence, which may be empty
        # @param lines [Array<String>] the lines between the fences
        #
        # @return [Block]
        def fenced_block(language, lines)
          language = language.downcase
          Block.new(type: :code, lines: dedent(lines), language: language.empty? ? nil : language)
        end

        # Returns true if the blank line at the given index is inside an indented code block, which
        # is when the chunk so far is all indented, and so is the next line that isn't blank.
        #
        # @param chunk [Array<String>]
        # @param lines [Array<String>]
        # @param index [Integer]
        #
        # @return [Boolean]
        def code_continues?(chunk, lines, index)
          return false unless code_chunk?(chunk)

          following = lines[(index + 1)..].find { |line| !line.strip.empty? }
          !following.nil? && INDENTED.match?(following)
        end

        # Returns true if the given chunk is an indented code block: it has lines, and every line is
        # either indented or blank.
        #
        # @param chunk [Array<String>]
        #
        # @return [Boolean]
        def code_chunk?(chunk)
          chunk.any? && chunk.all? { |line| line.strip.empty? || INDENTED.match?(line) }
        end

        # Adds the blocks for a chunk of text, which is a run of lines with no blank line between.
        #
        # If every line is indented, the whole chunk is a code block. Otherwise, it's split into
        # paragraphs and lists. A list doesn't need a blank line before it, so a line like "Paths:"
        # can be followed directly by a list.
        #
        # @param blocks [Array<Block>] the blocks so far, which this modifies
        # @param chunk [Array<String>]
        #
        # @return [void]
        def add_chunk(blocks, chunk)
          return if chunk.empty?
          return blocks << Block.new(type: :code, lines: dedent(chunk), language: nil) if code_chunk?(chunk)

          blocks.concat(chunk.each_with_object([]) { |line, chunk_blocks| add_line(chunk_blocks, line) })
        end

        # Adds a line to the given blocks, either starting a new block, or adding to the last one.
        #
        # A list item starts a new list, or adds to the list before it. Any other line starts a new
        # paragraph, or adds to the paragraph before it. The exception is an indented line after a
        # list item, which continues that item after a line break.
        #
        # @param blocks [Array<Block>] the blocks so far, which this modifies
        # @param line [String]
        #
        # @return [void]
        def add_line(blocks, line)
          last = blocks.last
          item = LIST_ITEM.match(line)

          if !item && last&.type == :list && line.start_with?(" ", "\t")
            last.lines[-1] = "#{last.lines[-1]}\n#{line.strip}"
            return
          end

          type = item ? :list : :paragraph
          blocks << (last = Block.new(type:, lines: [])) unless last&.type == type
          last.lines << (item ? item[1] : line)
        end

        # Removes the indentation shared by all the given lines, keeping any extra indentation on
        # individual lines. Blank lines become empty.
        #
        # @param lines [Array<String>]
        #
        # @return [Array<String>]
        def dedent(lines)
          indent = lines.reject { |line| line.strip.empty? }.map { |line| line[/\A[ \t]*/].length }.min || 0
          lines.map { |line| line.strip.empty? ? "" : line[indent..] }
        end
      end
    end
  end
end
