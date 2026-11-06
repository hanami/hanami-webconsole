# frozen_string_literal: true

require_relative "../safety"

module Hanami
  module Webconsole
    module Rendering
      # Renders an {ErrorPage} as Markdown.
      #
      # This backs both the "Copy as text" button and the `text/plain` response, so it has two
      # audiences: a GitHub issue or an LLM prompt, and a terminal. It is a deliverable, not a debug
      # dump. App frames are indented and gem frames are commented out, so the shape of the stack is
      # readable at a glance.
      #
      # Like the HTML page, this must never raise, since a failure here would leave the developer
      # with nothing at all. If any part of the error can't be read, that part is left out.
      #
      # @api private
      class Markdown
        include Safety

        # The maximum number of backtrace frames to list. Any further frames are counted, but not
        # listed.
        MAX_FRAMES = 25

        # The maximum number of a diagnostic's dataset rows to list. Any further rows are counted,
        # but not listed.
        #
        # A dataset can be long (such as the routes of a large app). The page shows all of it, but
        # in an issue, a prompt or a terminal, the first rows are enough, and the rest is noise.
        MAX_DATASET_ROWS = 50

        # @return [ErrorPage]
        attr_reader :page

        # @param page [ErrorPage]
        def initialize(page)
          @page = page
        end

        # Returns the error as Markdown.
        #
        # @return [String]
        def to_s
          safely(fallback) { blocks.compact.join("\n\n") + "\n" }
        end

        private

        # Returns the blocks of the output, in the same order as they appear on the page.
        #
        # Text from a diagnostic is already Markdown, so it's included as it is.
        #
        # @return [Array<String, nil>] the blocks, with nil for any block that has nothing to show
        def blocks
          [
            heading,
            message_block,
            diagnostic_text(&:explanation),
            metadata_block,
            diagnostic_text { |diagnostic| fix_text(diagnostic.fix) if diagnostic.fix },
            diagnostic_text { |diagnostic| dataset_text(diagnostic.dataset) if diagnostic.dataset },
            backtrace_block,
            source_block
          ]
        end

        # Returns the heading, which matches the page's headline.
        #
        # This is the diagnostic's title, if there is one, followed by the exception's class name.
        # On the page, the class name is in the top bar, so here it goes in the heading instead.
        #
        # @return [String]
        def heading
          title = diagnostic_text(&:title)
          title ? "## #{title} (#{page.exception_class})" : "## #{page.exception_class}"
        end

        def metadata_block
          bullets = []
          bullets << "- Request: #{request_summary}" if request_summary
          bullets << "- Status: #{page.status}"
          bullets << "- Caused by: #{page.causes.join(' → ')}" if page.causes.any?
          bullets.join("\n")
        end

        def request_summary
          return @request_summary if defined?(@request_summary)

          @request_summary = safely(nil) {
            summary = "#{page.request.method_name} #{page.request.path}".strip
            summary.empty? ? nil : summary
          }
        end

        # Returns one part of the diagnostic as text, using the given block.
        #
        # @yieldparam diagnostic [Hanami::Diagnostics::Wrapper]
        # @yieldreturn [String, nil] the part as text, or nil if the diagnostic doesn't have it
        #
        # @return [String, nil] nil if there's no diagnostic, or the diagnostic doesn't have the
        #   part
        def diagnostic_text
          diagnostic = page.diagnostic
          return nil unless diagnostic

          safely(nil) { yield(diagnostic) }
        end

        # Returns the diagnostic's fix as text, headed with the fix's name, or a generic heading.
        #
        # @param fix [Hanami::Diagnostics::Wrapper::Fix]
        #
        # @return [String]
        def fix_text(fix)
          heading = fix.name ? "### Fix: #{fix.name}" : "### Fix it"
          "#{heading}\n\n#{fix.text.strip}"
        end

        # Returns the diagnostic's dataset as text, headed with the dataset's title.
        #
        # A dataset with column headings becomes a Markdown table. Without column headings, it
        # becomes a list, with each row's cells joined by dashes.
        #
        # Only the first {MAX_DATASET_ROWS} rows are listed. Any further rows are counted, but not
        # listed.
        #
        # @param dataset [Hanami::Diagnostics::Wrapper::Dataset]
        #
        # @return [String]
        def dataset_text(dataset)
          listed = dataset.rows.first(MAX_DATASET_ROWS)

          rows =
            if dataset.columns.any?
              [
                table_row(dataset.columns),
                table_row(dataset.columns.map { "---" }),
                *listed.map { |row| table_row(row) }
              ]
            else
              listed.map { |row| "- #{row.reject(&:empty?).join(" — ")}" }
            end

          text = "### #{dataset.title}\n\n#{rows.join("\n")}"

          remaining = dataset.rows.length - listed.length
          text += "\n\n… #{remaining} more #{pluralize(remaining, 'row')}" if remaining.positive?

          text
        end

        # Returns a row of a Markdown table, escaping any pipe characters in the cells.
        #
        # @param cells [Array<String>]
        #
        # @return [String]
        def table_row(cells)
          "| #{cells.map { |cell| cell.gsub("|", "\\|") }.join(" | ")} |"
        end

        # Returns the exception's message and the lines `detailed_message` adds to it, in a fenced
        # block, so they show exactly as written, the same as in a terminal.
        #
        # The fence has more backticks than any run of backticks in the text, so nothing in the text
        # can close it.
        #
        # @return [String, nil] nil if there's no message and no extra lines
        def message_block
          lines = [page.message, *page.detailed_extras].reject(&:empty?)
          return nil if lines.empty?

          text = lines.join("\n")
          fence = "`" * [3, (text.scan(/`+/).map(&:length).max || 0) + 1].max
          "#{fence}\n#{text}\n#{fence}"
        end

        def backtrace_block
          frames = page.frames
          listed = frames.first(MAX_FRAMES)
          return nil if listed.empty?

          lines = [backtrace_heading]
          lines.concat(listed.map { |frame| frame_text(frame) })

          remaining = frames.length - listed.length
          lines << "  # … #{remaining} more #{pluralize(remaining, 'frame')}" if remaining.positive?

          lines.join("\n")
        end

        def backtrace_heading
          app_count = page.app_frames.length
          "### Backtrace (#{app_count} application #{pluralize(app_count, 'frame')} of #{page.frames.length})"
        end

        # App frames are indented, gem and core frames are commented out. Both prefixes are the
        # same width, so the paths line up and the app frames read as the signal they are.
        #
        # A frame's values can't raise (see {Frame}), so they aren't guarded here.
        def frame_text(frame)
          prefix = frame.app? ? "    " : "  # "
          location = "#{frame.display_path}:#{frame.lineno}"

          frame.label.empty? ? "#{prefix}#{location}" : "#{prefix}#{location}:in '#{frame.label}'"
        end

        def source_block
          frame = source_frame
          return nil unless frame

          excerpt = frame.source
          return nil unless excerpt

          lines = excerpt.lines
          return nil if lines.empty?

          [
            "### Source: #{frame.display_path}:#{frame.lineno}",
            "```ruby",
            *excerpt_lines(excerpt, lines),
            "```"
          ].join("\n")
        end

        # The frame worth showing source for: the first application frame, since that is where the
        # developer can act. Falls back to the raise point when the stack never enters the app.
        def source_frame
          return @source_frame if defined?(@source_frame)

          @source_frame = page.app_frames.first || page.frames.first
        end

        def excerpt_lines(excerpt, lines)
          first_lineno = excerpt.first_lineno
          highlight = excerpt.highlight_lineno
          width = (first_lineno + lines.length - 1).to_s.length

          lines.each_with_index.map { |line, index|
            lineno = first_lineno + index
            marker = lineno == highlight ? ">" : " "

            "#{marker} #{lineno.to_s.rjust(width)} | #{line}".rstrip
          }
        end

        # The output when nothing else can be rendered: just the exception's class name.
        def fallback
          "## #{safely('Exception') { page.exception_class }}\n"
        end

        def pluralize(count, noun)
          count == 1 ? noun : "#{noun}s"
        end
      end
    end
  end
end
