# frozen_string_literal: true

module Hanami
  module Diagnostics
    # A parser for the diagnostics text format.
    #
    # Diagnostics use this format for their explanation and fix. It's a subset of Markdown
    # that looks natural as plain text, since diagnostics are also read as text (such as in the
    # error's Markdown output).
    #
    # Exception messages are not parsed. They are shown exactly as written, the same as in a
    # terminal, since most aren't written for any format, and their layout (such as the carets
    # under a syntax error) only makes sense as it is.
    #
    # The text is read one line at a time:
    #
    # - a blank line ends the current block;
    # - a line starting with `- ` starts a list, or adds an item to the list before it;
    # - any other line after a list item continues that item, after a line break, so a list ends
    #   only at a blank line;
    # - any other line starts a paragraph, or adds to the paragraph before it, after a line break;
    # - a fence starts a code block, with an optional language (`sh` for a shell command), but only
    #   if a closing fence comes after it.
    #
    # Backticks mark inline code. These are part of the format, but each consumer handles them as it
    # renders, since that depends on how the text is escaped (see
    # {Webconsole::Rendering::HTML#inline_html}).
    #
    # There is no emphasis, links, headings, tables or indented code, so a `*` or `_` (as in a name
    # interpolated into a diagnostic) never turns into formatting by mistake. Use a fence for code.
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

      # The languages that mark a code block as shell commands.
      SHELL_LANGUAGES = %w[sh shell bash console].freeze

      class << self
        # Parses the given text into blocks.
        #
        # Each branch of the loop is one of the rules above. These are kept together, so the whole
        # format can be read in one place. Fences come first, so a fence after a list item or a
        # paragraph line still starts a code block.
        #
        # @param text [String, nil]
        #
        # @return [Array<Block>] the blocks, in order
        def blocks(text) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          lines = text.to_s.gsub(/\r\n?/, "\n").split("\n")
          blocks = []
          index = 0

          while index < lines.length
            line = lines[index]
            last = blocks.last

            if (fence = FENCE_OPEN.match(line)) && (close = closing_fence(lines, index, fence[1]))
              blocks << fenced_block(fence[2], lines[(index + 1)...close])
              index = close
            elsif line.strip.empty?
              # A nil ends the last block, so the next line starts a new one.
              blocks << nil
            elsif (item = LIST_ITEM.match(line))
              blocks << (last = Block.new(type: :list, lines: [])) unless last&.type == :list
              last.lines << item[1]
            elsif last&.type == :list
              last.lines[-1] = "#{last.lines[-1]}\n#{line.strip}"
            elsif last&.type == :paragraph
              last.lines << line
            else
              blocks << Block.new(type: :paragraph, lines: [line])
            end

            index += 1
          end

          blocks.compact
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

        # Removes the indentation shared by all the given lines, keeping any extra indentation on
        # individual lines. Blank lines become empty.
        #
        # This lets a fence be indented (such as under a list item) without its code being indented
        # too.
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
