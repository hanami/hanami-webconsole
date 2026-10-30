# frozen_string_literal: true

require "erb"
require "json"
require "rack/utils"

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

        # Icons for panel titles. Unknown titles fall back to a list icon.
        PANEL_ICONS = {
          "Cookies" => "lock",
          "Headers" => "list",
          "Params" => "braces",
          "Request" => "globe",
          "Routes" => "route",
          "Session" => "key"
        }.freeze

        # Panels longer than this get a search box. The request summary never does: it is short and
        # fixed, and reads as a caption rather than as a table.
        SEARCHABLE_FROM = 6

        # The titles of panels that never get a search box, however many rows they have.
        UNSEARCHABLE_PANELS = ["Request"].freeze

        # The most columns a panel can have and still fit alongside other panels. A panel with more
        # columns than this spans the full width of the page.
        NARROW_COLUMNS = 2

        # The value shown in place of anything the logger's filters have hidden.
        FILTERED = "[FILTERED]"

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
            @template ||= ERB.new(File.read(TEMPLATE_PATH), trim_mode: "-")
          end

          # Read once and held for the life of the process: the same assets are inlined into
          # every error page.
          #
          # @return [String]
          def asset(name)
            @assets ||= {}
            @assets[name] ||= File.read(File.join(TEMPLATE_DIR, ASSETS.fetch(name)))
          end
        end

        # @return [ErrorPage]
        attr_reader :page

        # The CSRF token is optional: a page rendered without one still shows everything except a
        # working console, and the console falls back to the cookie when the middleware sets a
        # readable one.
        #
        # @param page [ErrorPage]
        # @param nonce [String] the CSP nonce for the page's `<style>` and `<script>`
        # @param csrf_token [String, nil]
        def initialize(page, nonce:, csrf_token: nil)
          @page = page
          @nonce = nonce.to_s
          @csrf_token = csrf_token
        end

        # Returns the error page as HTML.
        #
        # @return [String]
        def to_s
          self.class.template.result(binding)
        end

        private

        attr_reader :nonce, :csrf_token

        # Inlined verbatim. These are our own files, never user input, so they are deliberately
        # not escaped — escaping them would break the CSS and JS.
        #
        # @return [String]
        def stylesheet
          self.class.asset(:stylesheet)
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

        # Returns the name of the icon to show next to the status code.
        #
        # @return [String]
        def status_icon
          actionable? ? "wrench" : "triangle-alert"
        end

        # @return [String]
        def status_label
          [status_code, status_reason].reject(&:empty?).join(" ")
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

        # Returns the heading for the fix card.
        #
        # This is the fix's name, or a generic heading if the fix has no name. When a named fix can
        # be run, there's no heading, since the name goes on the run button instead, and we don't
        # want to show it twice.
        #
        # @return [String, nil]
        def fix_heading
          return nil if runnable_fix? && fix.name

          fix.name || "Fix it"
        end

        # Returns the label for the button that runs the fix.
        #
        # This is the fix's name, or a generic label if the fix has no name.
        #
        # @return [String]
        def run_label
          fix.name || "Run this fix"
        end

        # @return [Array<String>]
        def extras
          @extras ||= trim_blanks(Array(page.detailed_extras).map { |line| line.to_s.chomp })
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

        # @return [Array<String>]
        def causes
          page.causes
        end

        # The topbar summary. Built here, from escaped parts, so the template interpolates it whole.
        #
        # @return [String]
        def request_summary_html
          request = page.request
          parts = ["<b>#{h(request.method_name)}</b> #{h(request.path)}"]
          parts << "slice <b>#{h(request.slice_name)}</b>" if request.slice_name
          parts << "route <b>#{h(request.route)}</b>" if request.route
          parts.join(" &middot; ")
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

        # @return [String]
        def meta_line
          [
            defined?(Hanami::VERSION) ? "Hanami #{Hanami::VERSION}" : nil,
            RUBY_DESCRIPTION
          ].compact.join(" • ")
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
        #
        # @return [String]
        def text_html(text)
          Hanami::Diagnostics::Text.blocks(text).map { |block| block_html(block) }.join("\n")
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
          h(text).gsub(CODE_SPAN) {
            match = Regexp.last_match
            "<code>#{match[1] || match[2] || match[3]}</code>"
          }
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
            "pageId" => page.id,
            "evalPath" => "#{MOUNT_PATH}/#{page.id}/eval",
            "runPath" => "#{MOUNT_PATH}/#{page.id}/run",
            "retryable" => RETRYABLE_METHODS.include?(page.request.method_name.to_s.upcase),
            "csrfToken" => csrf_token,
            "csrfCookie" => CSRF_COOKIE_NAME,
            "bindingsAvailable" => Webconsole.bindings_available?,
            "initialFrame" => initial_frame_index,
            "text" => Markdown.new(page).to_s,
            "frames" => frames.each_with_index.map { |frame, index| frame_payload(frame, index) }
          }
        end

        def frame_payload(frame, index)
          excerpt = frame.source

          {
            "index" => index,
            "kind" => frame.kind.to_s,
            "path" => frame.path,
            "displayPath" => frame.display_path,
            "line" => frame.lineno,
            "label" => frame.label,
            "binding" => !frame.binding.nil?,
            "receiver" => frame.receiver_inspect,
            "editorUrl" => frame.path ? editor.url(frame.path, frame.lineno) : nil,
            "start" => excerpt&.first_lineno,
            "src" => excerpt&.lines,
            "locals" => variables(frame.locals),
            "ivars" => variables(frame.instance_vars)
          }
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

        def variables(variables)
          Array(variables).map { |variable| [variable.name, variable.class_name, variable.value] }
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
            ["route", request.route],
            ["action", request.action_name],
            ["slice", request.slice_name],
            ["ip", request.ip]
          ].reject { |(_, value)| value.nil? || value.to_s.empty? }
            .map { |(name, value)| row(name, value) }
        end

        def hash_rows(hash)
          hash.map { |name, value| row(name, value) }
        end

        # Returns a name and value as a row, marked if the logger's filters replaced the value.
        #
        # @param name [#to_s]
        # @param value [#to_s]
        #
        # @return [Row]
        def row(name, value)
          value = value.to_s
          Row.new(cells: [name.to_s, value], filtered: value == FILTERED)
        end

        # Returns a context panel, ready for the template.
        #
        # A panel with more than {NARROW_COLUMNS} columns is marked as wide, so it spans the full
        # width of the page. A panel with enough rows gets a filter box (see {#searchable?}).
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
            icon: PANEL_ICONS.fetch(title, "list"),
            search: searchable?(title, rows) ? "Filter #{title.downcase}" : nil,
            noun: panel_noun(title),
            columns:,
            wide: [width, columns.length].max > NARROW_COLUMNS,
            rows:
          }
        end

        def searchable?(title, rows)
          !UNSEARCHABLE_PANELS.include?(title) && rows.length >= SEARCHABLE_FROM
        end

        def panel_noun(title)
          label = title.downcase
          label.match?(/\A\w+s\z/) ? label : "rows"
        end
      end
    end
  end
end
