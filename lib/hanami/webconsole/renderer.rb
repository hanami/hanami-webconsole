# frozen_string_literal: true

require "erb"
require "json"
require "rack/utils"

module Hanami
  module Webconsole
    # Renders an {ErrorPage} as HTML, plain text or JSON.
    #
    # The HTML template is self-contained: one nonced `<style>`, one nonced `<script>`, no external
    # assets and no build step. It is read from disk once and the compiled ERB is memoized, since
    # the same template renders every error for the life of the process.
    #
    # @api private
    module Renderer
      TEMPLATE_DIR = File.expand_path("templates", __dir__)
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

      # Name of the double-submit CSRF cookie set by the middleware.
      CSRF_COOKIE_NAME = Webconsole::CSRF_COOKIE_NAME

      MOUNT_PATH = Webconsole::MOUNT_PATH

      class << self
        # The CSRF token is optional: a page rendered without one still shows everything except a
        # working console, and the console falls back to the cookie when the middleware sets a
        # readable one.
        #
        # @return [String]
        def render_html(page, nonce:, csrf_token: nil)
          template.result(Scope.new(page:, nonce:, csrf_token:).template_binding)
        end

        # @return [String]
        def render_text(page)
          page.to_text
        end

        # @return [String]
        def render_json(page)
          request = page.request

          JSON.generate(
            "error" => page.exception_class,
            "message" => page.message,
            "status" => page.status,
            "actionable" => page.actionable?,
            "diagnostic" => diagnostic_json(page.diagnostic),
            "causes" => page.causes,
            "backtrace" => page.frames.map { |frame|
              "#{frame.path}:#{frame.lineno}:in '#{frame.label}'"
            },
            "request" => {
              "method" => request.method_name,
              "path" => request.path,
              "format" => request.format,
              "ip" => request.ip,
              "params" => request.params
            }
          )
        end

        # Read once and held for the life of the process: the same assets are inlined into
        # every error page. Public because {Scope} calls it from the template.
        #
        # @return [String]
        def asset(name)
          @assets ||= {}
          @assets[name] ||= File.read(File.join(TEMPLATE_DIR, ASSETS.fetch(name)))
        end

        private

        def template
          @template ||= ERB.new(File.read(TEMPLATE_PATH), trim_mode: "-")
        end

        def diagnostic_json(diagnostic)
          return nil unless diagnostic

          fix = diagnostic.fix
          dataset = diagnostic.dataset

          {
            "title" => diagnostic.title,
            "explanation" => diagnostic.explanation,
            "fix" => fix && {"name" => fix.name, "text" => fix.text, "runnable" => diagnostic.runnable_fix?},
            "dataset" => dataset && {"title" => dataset.title, "columns" => dataset.columns, "rows" => dataset.rows}
          }
        end
      end

      # The binding the template renders against.
      #
      # Everything the template interpolates arrives already escaped from here: the template calls
      # `h` (never `to_s`) on any value that originates outside the framework.
      class Scope
        # Icons for panel titles. Unknown titles fall back to a list icon.
        PANEL_ICONS = {
          "Request" => "globe", "Params" => "braces", "Session" => "key", "Cookies" => "lock",
          "Headers" => "list", "Routes" => "route"
        }.freeze

        # Panels longer than this get a search box. The request summary never does: it is short and
        # fixed, and reads as a caption rather than as a table.
        SEARCHABLE_FROM = 6

        UNSEARCHABLE_PANELS = ["Request"].freeze

        # A table with more columns than this spans the full width of the context grid.
        NARROW_COLUMNS = 2

        FILTERED = "[FILTERED]"

        # Request methods for which reloading the page repeats the original request.
        RETRYABLE_METHODS = %w[GET HEAD].freeze

        # A `'quoted'`, `` `quoted' `` or `` `backticked` `` run in escaped text. See
        # {#inline_html}.
        CODE_SPAN = /
          (?<![[:alnum:]])&\#39;([^&<>\s]+)&\#39;(?![[:alnum:]])
          |`([^`&<>\s]+)&\#39;(?![[:alnum:]])
          |`([^`&<>]*)`
        /x

        # One row of a context panel. `filtered` marks a value the logger's filters replaced.
        Row = Struct.new(:cells, :filtered, keyword_init: true)

        attr_reader :page, :nonce, :csrf_token

        def initialize(page:, nonce:, csrf_token: nil)
          @page = page
          @nonce = nonce.to_s
          @csrf_token = csrf_token
        end

        def template_binding
          binding
        end

        # Inlined verbatim. These are our own files, never user input, so they are deliberately
        # not escaped — escaping them would break the CSS and JS.
        #
        # @return [String]
        def stylesheet
          Renderer.asset(:stylesheet)
        end

        # @return [String]
        def javascript
          Renderer.asset(:javascript)
        end

        # @return [String]
        def icon_sprite
          Renderer.asset(:icon_sprite)
        end

        # @return [String]
        def h(value)
          # Use ERB::Util rather than Rack::Utils.
          #
          # Rack v2 escapes `'` as `&#x27;` and `/` as `&#x2F;`, while Rack v3 gives `&#39;` and
          # leaves `/` alone. ERB gives the same output on both, which {CODE_SPAN} relies on.
          ERB::Util.html_escape(value.to_s)
        end

        # @return [Boolean]
        def actionable?
          page.actionable?
        end

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

        # @return [Array]
        def frames
          @frames ||= page.frames
        end

        # @return [Integer]
        def app_frames_count
          @app_frames_count ||= frames.count(&:app?)
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

        # Only a crash leads with the backtrace. When the page offers a fix, the backtrace starts
        # collapsed behind a disclosure.
        #
        # @return [Boolean]
        def collapsed?
          actionable?
        end

        # @return [Diagnostics::Wrapper, nil]
        def diagnostic
          page.diagnostic
        end

        # A diagnostic's short name for the situation.
        #
        # @return [String, nil]
        def title
          diagnostic&.title
        end

        # A diagnostic's title names the situation in place of the class name. The class name is
        # always in the topbar, so nothing is lost. The message is always shown under the headline.
        #
        # @return [String]
        def headline
          title || page.exception_class
        end

        # @return [Boolean]
        def message?
          !page.message.empty?
        end

        # @return [String]
        def message_html
          text_html(page.message)
        end

        # @return [String, nil]
        def explanation
          diagnostic&.explanation
        end

        # @return [Diagnostics::Wrapper::Fix, nil]
        def fix
          diagnostic&.fix
        end

        # @return [Boolean]
        def runnable_fix?
          !!diagnostic&.runnable_fix?
        end

        # When a named fix can run, its name goes on the button only, so the card doesn't show it
        # twice.
        #
        # @return [String, nil]
        def fix_heading
          return nil if runnable_fix? && fix.name

          fix.name || "Fix it"
        end

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
          @causes ||= Array(page.causes)
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

        # The diagnostic's dataset, if any, then the request.
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
          JSON.generate(payload).gsub(/[<>&  ]/) { |char| format('\u%04x', char.ord) }
        end

        # Renders text in the format messages and diagnostics share (see {Text}): paragraphs,
        # lists and code blocks. A shell block shows as a command with a prompt, and any code block
        # gets a copy button.
        #
        # @return [String]
        def text_html(text)
          Text.blocks(text).map { |block| block_html(block) }.join("\n")
        end

        # Wraps quoted or backticked runs in `<code>`, the way the design shows identifiers in the
        # lede. Runs after escaping, on escaped text, so it can only ever add `<code>` tags.
        #
        # Single quotes are for Ruby's own messages, which quote names that way (`undefined method
        # 'titel' for an instance of Book`), and a backtick closed by a single quote is the older
        # Ruby style some messages still use (`` `index' ``). Only quotes that work as quotes count:
        # the opening quote must not follow a letter or digit, the closing quote must not come
        # before one, and there is no whitespace between them. An apostrophe in ordinary English
        # (`slice's`, `can't`, `users'`) therefore stays as text, and writers need no rule other
        # than to use backticks for code.
        #
        # @return [String]
        def inline_html(text)
          h(text).gsub(CODE_SPAN) {
            match = Regexp.last_match
            "<code>#{match[1] || match[2] || match[3]}</code>"
          }
        end

        private

        def block_html(block)
          case block.type
          when :paragraph
            "<p>#{block.lines.map { |line| inline_html(line) }.join("<br>\n")}</p>"
          when :list
            "<ul>#{block.lines.map { |item| "<li>#{inline_html(item)}</li>" }.join}</ul>"
          else
            code_html(block)
          end
        end

        def code_html(block)
          code = h(block.lines.join("\n"))

          if Text.shell?(block)
            %(<div class="cmd"><span class="prompt">$</span><code data-webconsole-command>#{code}</code>) +
              copy_button("command") + "</div>"
          else
            highlight = block.language == "ruby" ? " data-webconsole-highlight" : ""
            %(<div class="snippet-wrap"><pre class="snippet" data-webconsole-snippet#{highlight}>#{code}</pre>) +
              copy_button("snippet") + "</div>"
          end
        end

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
            "text" => page.to_text,
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

        def diagnostic_panels
          dataset = diagnostic&.dataset
          return [] unless dataset

          rows = dataset.rows.map { |cells| Row.new(cells: cells, filtered: false) }
          [panel(dataset.title, rows, columns: dataset.columns)]
        rescue StandardError
          []
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
            .map { |(name, value)| Row.new(cells: [name, value.to_s], filtered: value.to_s == FILTERED) }
        end

        def hash_rows(hash)
          hash.map { |name, value| Row.new(cells: [name.to_s, value.to_s], filtered: value.to_s == FILTERED) }
        end

        def panel(title, rows, columns: [])
          width = rows.map { |row| row.cells.length }.max || columns.length

          {
            title: title,
            icon: PANEL_ICONS.fetch(title, "list"),
            search: searchable?(title, rows) ? "Filter #{title.downcase}" : nil,
            noun: panel_noun(title),
            columns: columns,
            wide: [width, columns.length].max > NARROW_COLUMNS,
            rows: rows
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
