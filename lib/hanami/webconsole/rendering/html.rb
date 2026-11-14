# frozen_string_literal: true

require "erb"
require "json"
require "rack/utils"

require_relative "../filters"

module Hanami
  module Webconsole
    module Rendering
      # Renders an {ErrorPage} as HTML, for the error page in the browser.
      #
      # The template is self-contained: one nonced `<style>`, one nonced `<script>`, no external
      # assets and no build step. It is read from disk once and the compiled ERB is memoized, since
      # the same template renders every error for the life of the process.
      #
      # The template renders against this object's binding, so it calls the private methods below.
      # Everything the template interpolates arrives already escaped from these: the template calls
      # `h` (never `to_s`) on any value that originates outside the framework.
      #
      # @api private
      class HTML
        # The directory holding the template and its assets.
        TEMPLATE_DIR = File.expand_path("../templates", __dir__)

        # The path to the page's ERB template.
        TEMPLATE_PATH = File.join(TEMPLATE_DIR, "error.html.erb")

        # Static assets inlined into the page. They live in their own files so the markup stays
        # reviewable and editors treat them as CSS/JS/SVG rather than as one giant ERB blob.
        # None of them contain ERB — everything dynamic reaches the page through the template or
        # the JSON island.
        ASSETS = {
          stylesheet: "error.css",
          javascript: "error.js",
          icon_sprite: "icons.svg"
        }.freeze

        # The most columns a panel can have and still fit alongside other panels. A panel with more
        # columns than this spans the full width of the page.
        NARROW_COLUMNS = 2

        # The request methods we can safely retry after running a fix, by reloading the page.
        #
        # Reloading the page after any other request would either ask the browser to resubmit it, or
        # repeat an action without asking.
        RETRYABLE_METHODS = %w[GET HEAD].freeze

        # Matches a `'quoted'`, `` `quoted' `` or `` `backticked` `` piece of escaped text, to show
        # as code. A piece never runs over more than one line. See {#inline_html}.
        CODE_SPAN = /
          (?<![[:alnum:]])&\#39;([^&<>\s]+)&\#39;(?![[:alnum:]])
          |`([^`&<>\s]+)&\#39;(?![[:alnum:]])
          |`([^`&<>\n]+)`
        /x

        # An escaped straight apostrophe between a letter or digit and a letter.
        APOSTROPHE = /(?<=[[:alnum:]])&#39;(?=[[:alpha:]])/

        # A row in a context panel.
        #
        # @!attribute [r] cells
        #   @return [Array<String>]
        # @!attribute [r] filtered
        #   @return [Boolean] true if the row's value was replaced by the logger's filters
        Row = Struct.new(:cells, :filtered, keyword_init: true)

        class << self
          # @return [ERB]
          def template
            @template ||= ERB.new(File.read(TEMPLATE_PATH, encoding: Encoding::UTF_8), trim_mode: "-")
          end

          # Read once and held for the life of the process: the same assets are inlined into
          # every error page.
          #
          # The template and assets are UTF-8, so they're read as UTF-8 whatever the default
          # external encoding is. Without a UTF-8 locale (e.g. `LANG` unset in a Docker image), Ruby
          # would read them as US-ASCII, and joining them would raise `Encoding::CompatibilityError`.
          #
          # @return [String]
          def asset(name)
            @assets ||= {}
            @assets[name] ||= File.read(File.join(TEMPLATE_DIR, ASSETS.fetch(name)), encoding: Encoding::UTF_8)
          end
        end

        # @return [ErrorPage]
        attr_reader :page

        # The CSRF token is optional: a page rendered without one still shows everything except a
        # working console. The page can't read the token from the cookie instead, since the cookie
        # is `httponly`.
        #
        # @param page [ErrorPage]
        # @param nonce [String] the CSP nonce for the page's `<style>` and `<script>`
        # @param csrf_token [String, nil]
        # @param font_path [String] where the page loads its fonts from (see {Fonts})
        def initialize(page, nonce:, csrf_token: nil, font_path: Fonts::PATH)
          @page = page
          @nonce = nonce.to_s
          @csrf_token = csrf_token
          @font_path = font_path
        end

        # Returns the error page as HTML.
        #
        # @return [String]
        def to_s
          self.class.template.result(binding)
        end

        private

        attr_reader :nonce, :csrf_token, :font_path

        # Inlined verbatim. These are our own files, never user input, so they are deliberately
        # not escaped — escaping them would break the CSS and JS.
        #
        # @return [String]
        def stylesheet
          Fonts.css(font_path) + self.class.asset(:stylesheet)
        end

        # @return [String]
        def javascript
          self.class.asset(:javascript)
        end

        # @return [String]
        def icon_sprite
          self.class.asset(:icon_sprite)
        end

        # @return [String]
        def h(value)
          # Use ERB::Util rather than Rack::Utils.
          #
          # Rack v2 escapes `'` as `&#x27;` and `/` as `&#x2F;`, while Rack v3 gives `&#39;` and
          # leaves `/` alone. ERB gives the same output on both, which {CODE_SPAN} relies on.
          ERB::Util.html_escape(value.to_s)
        end

        # Returns true if the page offers a fix.
        #
        # @return [Boolean]
        def actionable?
          page.actionable?
        end

        # Split from the reason so narrow screens can keep the code and drop the words.
        #
        # @return [String]
        def status_code
          page.status.to_s
        end

        # @return [String]
        def status_reason
          Rack::Utils::HTTP_STATUS_CODES[page.status].to_s
        end

        # @return [Array<Frame>]
        def frames
          page.frames
        end

        # @return [Integer]
        def app_frames_count
          page.app_frames.length
        end

        # @return [Boolean]
        def app_only?
          app_frames_count.positive?
        end

        # The frames the checkbox hides: those from gems and the framework.
        #
        # @return [Integer]
        def hidden_frames_count
          frames.length - app_frames_count
        end

        # Start on the first frame the developer wrote, not on the middleware that caught it.
        #
        # @return [Integer]
        def initial_frame_index
          @initial_frame_index ||= frames.index(&:app?) || 0
        end

        # Returns true if the backtrace should start collapsed.
        #
        # When the page offers a fix, the fix leads, and the backtrace starts collapsed behind a
        # disclosure. Otherwise, the backtrace is the developer's best lead, so it starts open.
        #
        # @return [Boolean]
        def collapsed?
          actionable?
        end

        # Returns the diagnostic for the exception, if there is one.
        #
        # @return [Hanami::Diagnostics::Wrapper, nil]
        def diagnostic
          page.diagnostic
        end

        # Returns the diagnostic's title, if there is one.
        #
        # @return [String, nil]
        def title
          diagnostic&.title
        end

        # Returns the page's headline.
        #
        # This is the diagnostic's title, if there is one, or otherwise the exception's class name.
        # The class name is always shown in the top bar, so nothing is lost when a title replaces
        # it. The exception's message is always shown under the headline.
        #
        # @return [String]
        def headline
          title || page.exception_class
        end

        # Returns true if the exception has a message to show.
        #
        # @return [Boolean]
        def message?
          !page.message.empty?
        end

        # Returns the exception's message as HTML.
        #
        # The message is shown exactly as written, the same as in a terminal. It's not parsed as
        # text (see {Hanami::Diagnostics::Text}), since most messages aren't written for any format,
        # and their layout (such as the carets under a syntax error) only makes sense as it is.
        #
        # Quoted names are still shown as code, but they keep their quotes, so every character stays
        # in its column.
        #
        # @return [String]
        def message_html
          h(page.message).gsub(CODE_SPAN) { "<code>#{Regexp.last_match[0]}</code>" }
        end

        # Returns the diagnostic's explanation, if there is one.
        #
        # @return [String, nil]
        def explanation
          diagnostic&.explanation
        end

        # Returns the diagnostic's fix, if there is one.
        #
        # @return [Hanami::Diagnostics::Wrapper::Fix, nil]
        def fix
          diagnostic&.fix
        end

        # Returns true if the diagnostic has a fix that can be run from the page.
        #
        # @return [Boolean]
        def runnable_fix?
          !!diagnostic&.runnable_fix?
        end

        # Returns the heading under the fix card's "Fix" label: the fix's name, or nil.
        #
        # A fix that can run has no heading, since its name goes on the run button instead, and we
        # don't want to show it twice. An unnamed fix needs none beyond the label.
        #
        # @return [String, nil]
        def fix_heading
          fix.name unless runnable_fix?
        end

        # Returns the label for the button that runs the fix.
        #
        # This is the fix's name, or a generic label if the fix has no name.
        #
        # @return [String]
        def run_label
          fix.name || "Run this fix"
        end

        # The `detailed_message` extras to show under the message: usually error_highlight's code
        # line and carets.
        #
        # When there's a suggestion, the callout shows did_you_mean's lines, so they're dropped
        # here. The lines lose their shared indent, which comes from the source and only pushes the
        # code away from the box's edge.
        #
        # @return [Array<String>]
        def extras
          @extras ||= begin
            lines = trim_blanks(Array(page.detailed_extras).map { |line| line.to_s.chomp })
            lines = without_did_you_mean(lines) if suggestion
            dedent(trim_blanks(lines.reverse).reverse)
          end
        end

        # @return [ErrorPage::Suggestion, nil]
        def suggestion
          page.suggestion
        end

        # The suggestion as a sentence, with names as code.
        #
        # @return [String]
        def suggestion_html
          names = suggestion.corrections.map { |name| "<code>#{h(name)}</code>" }
          sentence = "Did you mean #{names.join(" or ")}?"
          return sentence unless suggestion.receiver_class

          "#{sentence} <code>#{h(suggestion.receiver_class)}</code> responds to it."
        end

        # The callout beside the header holds the fix if there is one, or else the suggestion.
        #
        # @return [Boolean]
        def callout?
          !fix.nil? || !suggestion.nil?
        end

        # `detailed_message` extras carry the error_highlight caret rows. Those get the signal
        # colour; everything else stays muted.
        #
        # @return [String]
        def extras_html
          extras.map { |line|
            if line.match?(/\A\s*[\^~]+\s*\z/)
              %(<span class="caret">#{h(line)}</span>)
            else
              h(line)
            end
          }.join("\n")
        end

        # @return [Array<ErrorPage::Cause>]
        def cause_details
          page.cause_details
        end

        # The topbar summary. Built here, from escaped parts, so the template interpolates it whole.
        #
        # @return [String]
        def request_summary_html
          request = page.request
          "<b>#{h(request.method_name)}</b> #{h(request.path)}"
        end

        # Returns the panels to show below the backtrace.
        #
        # The diagnostic's dataset comes first (if there is one), followed by the panels for the
        # request.
        #
        # @return [Array<Hash>]
        def context_panels
          @context_panels ||= (diagnostic_panels + request_panels)
        end

        # The panels, as wide ones (rows of their own) and then the rest (a grid of columns). A
        # wide panel in the grid would keep every column alive, squeezing the panels after it.
        #
        # @return [Array<Array(Boolean, Array<Hash>)>]
        def context_panel_groups
          wide, narrow = context_panels.partition { |panel| panel[:wide] }
          [[true, wide], [false, narrow]].reject { |(_, panels)| panels.empty? }
        end

        # The version of Hanami, if it's loaded. Webconsole doesn't depend on Hanami, so it may not be.
        #
        # @return [String, nil]
        def hanami_version
          Hanami::VERSION.to_s if defined?(Hanami::VERSION)
        end

        # The single JSON island the page's JavaScript reads.
        #
        # `<`, `>` and `&` become `\uXXXX` escapes: the contents of a `<script>` element are raw
        # text, so HTML entities would not decode, and an unescaped `</script>` inside a string
        # would end the element.
        #
        # @return [String]
        def payload_json
          ::JSON.generate(payload).gsub(/[<>&  ]/) { |char| format('\u%04x', char.ord) }
        end

        # Returns the given text as HTML.
        #
        # The text is parsed into paragraphs, lists and code blocks (see {Text}), which is the
        # format for a diagnostic's text. A code block of shell commands is shown as commands with a
        # `$` prompt, and every code block gets a copy button.
        #
        # @param text [String, nil]
        # @param lead [String, nil] words to lead into the text with, such as "Or do it yourself:"
        #
        # @return [String]
        def text_html(text, lead: nil)
          html = Hanami::Diagnostics::Text.blocks(text).map { |block| block_html(block) }
          return html.join("\n") unless lead

          with_lead(html, lead).join("\n")
        end

        # Puts a lead-in before the first block: inside it as the start of a sentence when it's a
        # paragraph, or on a line of its own before code or a list.
        def with_lead(html, lead)
          if html.first&.start_with?("<p>")
            [html.first.sub("<p>", %(<p><span class="fix-lead">#{h(lead)}</span> )), *html.drop(1)]
          else
            [%(<p class="fix-lead">#{h(lead)}</p>), *html]
          end
        end

        # Returns a line of text as HTML, with any quoted or backticked names wrapped in `<code>`.
        #
        # This escapes the text first, and only then looks for quoted names, so the only HTML it can
        # ever add is the `<code>` tags.
        #
        # As well as backticks, this handles the two ways Ruby quotes names in its messages:
        # single quotes (as in "undefined method 'titel' for an instance of Book"), and the older
        # style of a backtick closed by a single quote (as in "`index'").
        #
        # Only quotes that actually work as quotes count. The opening quote must not follow a letter
        # or digit, the closing quote must not come before one, and there can be no whitespace
        # between them. This means an apostrophe in ordinary English (such as in "slice's", "can't"
        # or "users'") stays as text, and writers don't need to follow any rule other than to use
        # backticks for code.
        #
        # @param text [String]
        #
        # @return [String]
        def inline_html(text)
          html = h(text).gsub(CODE_SPAN) {
            match = Regexp.last_match
            "<code>#{match[1] || match[2] || match[3]}</code>"
          }
          apostrophes(html)
        end

        # Returns escaped prose with each apostrophe between two letters (as in "haven't" or
        # "slice's") made typographic.
        #
        # This is for the prose webconsole renders: a diagnostic's title, explanation and fix. Code
        # spans are never touched, since {CODE_SPAN} can't match one holding an apostrophe. An
        # exception's message is shown exactly as Ruby wrote it, so it never comes through here.
        #
        # @param html [String] escaped HTML
        #
        # @return [String]
        def apostrophes(html)
          html.gsub(APOSTROPHE, "\u2019")
        end

        # Escaped prose, with typographic apostrophes. See {#apostrophes}.
        #
        # @param text [String]
        #
        # @return [String]
        def prose(text)
          apostrophes(h(text))
        end

        # Returns a block of parsed text as HTML.
        #
        # Within a paragraph or list item, each line break is kept as a `<br>`, since the text is
        # also read in a terminal, where line breaks matter.
        #
        # @param block [Hanami::Diagnostics::Text::Block]
        #
        # @return [String]
        def block_html(block)
          case block.type
          when :paragraph
            "<p>#{block.lines.map { |line| inline_html(line) }.join("<br>\n")}</p>"
          when :list
            items = block.lines.map { |item| item.split("\n").map { |line| inline_html(line) }.join("<br>") }
            "<ul>#{items.map { |item| "<li>#{item}</li>" }.join}</ul>"
          else
            code_html(block)
          end
        end

        # Returns a code block as HTML, with a copy button.
        #
        # A code block of shell commands is shown as commands with a `$` prompt. Any other code
        # block is shown as a snippet. Ruby snippets are marked to be syntax highlighted by the
        # page's JavaScript.
        #
        # @param block [Hanami::Diagnostics::Text::Block]
        #
        # @return [String]
        def code_html(block)
          code = h(block.lines.join("\n"))

          if Hanami::Diagnostics::Text.shell?(block)
            %(<div class="cmd"><span class="prompt">$</span><code data-webconsole-command>#{code}</code>) +
              copy_button("command") + "</div>"
          else
            highlight = block.language == "ruby" ? " data-webconsole-highlight" : ""
            %(<div class="snippet-wrap"><pre class="snippet" data-webconsole-snippet#{highlight}>#{code}</pre>) +
              copy_button("snippet") + "</div>"
          end
        end

        # Returns the HTML for a copy button.
        #
        # @param kind [String] what the button copies, either `"command"` or `"snippet"`
        #
        # @return [String]
        def copy_button(kind)
          %(<button type="button" class="copy-btn" data-webconsole-copy="#{kind}">) +
            %(<svg class="icon" aria-hidden="true"><use href="#i-copy"/></svg><span class="label">Copy</span></button>)
        end

        def payload
          {
            "variablesPath" => "#{MOUNT_PATH}/#{page.id}/variables",
            "evalPath" => "#{MOUNT_PATH}/#{page.id}/eval",
            "runPath" => "#{MOUNT_PATH}/#{page.id}/run",
            "retryable" => RETRYABLE_METHODS.include?(page.request.method_name.to_s.upcase),
            "csrfToken" => csrf_token,
            "bindingsAvailable" => Webconsole.bindings_available?,
            "initialFrame" => initial_frame_index,
            "text" => Markdown.new(page).to_s,
            "frames" => frames.each_with_index.map { |frame, index| frame_payload(frame, index) }
          }
        end

        # Returns a frame's data for the page's script.
        #
        # Every frame gets its source, as on Rails' error page: reading it is cheap, and the source
        # files are cached. Only the initial frame gets its variables, so the page opens with them
        # already shown. The script loads any other frame's variables when it's selected (see
        # {Middleware}). Inspecting a variable calls its own `#inspect`, which can take any amount
        # of time, so we don't do it for frames that are never looked at.
        #
        # @return [Hash]
        def frame_payload(frame, index)
          excerpt = frame.source

          payload = {
            "index" => index,
            "kind" => frame.kind.to_s,
            "path" => frame.path,
            "displayPath" => frame.display_path,
            "line" => frame.lineno,
            "label" => frame.label,
            "binding" => !frame.binding.nil?,
            "editorUrl" => frame.file? ? editor.url(frame.path, frame.lineno) : nil,
            "start" => excerpt&.first_lineno,
            "src" => excerpt&.lines
          }

          index == initial_frame_index ? payload.merge(variables_payload(frame)) : payload
        end

        # @return [Hash] the frame's variables, as rows for the page's variables table
        def variables_payload(frame)
          {
            "locals" => frame.locals.map(&:to_row),
            "ivars" => frame.instance_vars.map(&:to_row)
          }
        end

        # Drops did_you_mean's "Did you mean?" line and the indented corrections under it, one name
        # per line. error_highlight's carets always come before it, so they're never dropped.
        def without_did_you_mean(lines)
          start = lines.index { |line| line.lstrip.start_with?("Did you mean?") }
          return lines unless start

          rest = lines[(start + 1)..].drop_while { |line| line.match?(/\A\s+\S+\s*\z/) }
          lines[0...start] + rest
        end

        def dedent(lines)
          indent = lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].length }.min.to_i
          lines.map { |line| line[indent..] || "" }
        end

        def trim_blanks(lines)
          lines.drop_while { |line| line.strip.empty? }
            .reverse
            .drop_while { |line| line.strip.empty? }
            .reverse
        end

        def editor
          @editor ||= Editor.from_env
        end

        # Returns the panel for the diagnostic's dataset, if there is one.
        #
        # @return [Array<Hash>] the panel, or an empty array if there's no dataset
        def diagnostic_panels
          dataset = diagnostic&.dataset
          return [] unless dataset

          rows = dataset.rows.map { |cells| Row.new(cells:, filtered: false) }
          [panel(dataset.title, rows, columns: dataset.columns)]
        end

        def request_panels
          request = page.request
          hashes = {
            "Params" => request.params, "Session" => request.session,
            "Cookies" => request.cookies, "Headers" => request.headers
          }

          hashes.reject { |_, hash| hash.empty? }
            .map { |title, hash| panel(title, hash_rows(hash)) }
            .unshift(panel("Request", request_rows(request)))
        end

        def request_rows(request)
          [
            ["method", request.method_name],
            ["path", request.path],
            ["format", request.format],
            ["ip", request.ip]
          ].reject { |(_, value)| value.nil? || value.to_s.empty? }
            .map { |(name, value)| row(name, value) }
        end

        def hash_rows(hash)
          hash.map { |name, value| row(name, value) }
        end

        # Returns a name and value as a row, marked if the logger's filters replaced the value.
        #
        # The filters replace a value with {Filters::FILTERED} itself, so this checks for that exact
        # object. A value that merely reads `"[FILTERED]"` isn't marked.
        #
        # @param name [#to_s]
        # @param value [#to_s]
        #
        # @return [Row]
        def row(name, value)
          Row.new(cells: [name.to_s, value.to_s], filtered: value.equal?(Filters::FILTERED))
        end

        # Returns a context panel, ready for the template.
        #
        # A panel with more than {NARROW_COLUMNS} columns is marked as wide, so it spans the full
        # width of the page.
        #
        # @param title [String]
        # @param rows [Array<Row>]
        # @param columns [Array<String>] the column headings, if there are any
        #
        # @return [Hash]
        def panel(title, rows, columns: [])
          width = rows.map { |row| row.cells.length }.max || columns.length

          {
            title:,
            columns:,
            wide: [width, columns.length].max > NARROW_COLUMNS,
            rows:
          }
        end
      end
    end
  end
end
