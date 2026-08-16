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
    # @since 3.1.0
    module Renderer
      # @api private
      # @since 3.1.0
      TEMPLATE_DIR = File.expand_path("templates", __dir__)

      # @api private
      # @since 3.1.0
      TEMPLATE_PATH = File.join(TEMPLATE_DIR, "error.html.erb")

      # Static assets inlined into the page. They live in their own files so the markup stays
      # reviewable and editors treat them as CSS/JS/SVG rather than as one giant ERB blob.
      # None of them contain ERB — everything dynamic reaches the page through the template or
      # the JSON island.
      #
      # @api private
      # @since 3.1.0
      ASSETS = {
        stylesheet: "error.css",
        javascript: "error.js",
        icon_sprite: "icons.svg"
      }.freeze

      # Name of the double-submit CSRF cookie set by the middleware.
      #
      # @api private
      # @since 3.1.0
      CSRF_COOKIE_NAME = Webconsole::CSRF_COOKIE_NAME

      # @api private
      # @since 3.1.0
      MOUNT_PATH = Webconsole::MOUNT_PATH

      class << self
        # The CSRF token is optional: a page rendered without one still shows everything except a
        # working console, and the console falls back to the cookie when the middleware sets a
        # readable one.
        #
        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def render_html(page, nonce:, csrf_token: nil)
          template.result(
            Scope.new(page: page, nonce: nonce, csrf_token: csrf_token).template_binding
          )
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def render_text(page)
          page.to_text
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def render_json(page)
          request = page.request

          JSON.generate(
            "error" => page.exception_class,
            "message" => page.message,
            "status" => page.status,
            "severity" => page.severity.to_s,
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
        #
        # @api private
        # @since 3.1.0
        def asset(name)
          @assets ||= {}
          @assets[name] ||= File.read(File.join(TEMPLATE_DIR, ASSETS.fetch(name)))
        end

        private

        # @api private
        # @since 3.1.0
        def template
          @template ||= ERB.new(File.read(TEMPLATE_PATH), trim_mode: "-")
        end
      end

      # The binding the template renders against.
      #
      # Everything the template interpolates arrives already escaped from here: the template calls
      # `h` (never `to_s`) on any value that originates outside the framework.
      #
      # @api private
      # @since 3.1.0
      class Scope
        # @api private
        # @since 3.1.0
        SEVERITIES = {crash: "crash", actionable: "actionable", not_found: "notfound"}.freeze

        # @api private
        # @since 3.1.0
        SEVERITY_ICONS = {
          "crash" => "triangle-alert", "actionable" => "wrench", "notfound" => "signpost"
        }.freeze

        # Icons for panel titles a presenter may supply. Unknown titles fall back to a list icon.
        #
        # @api private
        # @since 3.1.0
        PANEL_ICONS = {
          "Request" => "globe", "Params" => "braces", "Session" => "key", "Cookies" => "lock",
          "Headers" => "list", "Database" => "database", "Routes" => "route",
          "Nearest registered keys" => "package"
        }.freeze

        # Panels longer than this get a search box. The request summary never does: it is short and
        # fixed, and reads as a caption rather than as a table.
        #
        # @api private
        # @since 3.1.0
        SEARCHABLE_FROM = 6

        # @api private
        # @since 3.1.0
        UNSEARCHABLE_PANELS = ["Request"].freeze

        # @api private
        # @since 3.1.0
        FILTERED = "[FILTERED]"

        attr_reader :page, :nonce, :csrf_token

        # @api private
        # @since 3.1.0
        def initialize(page:, nonce:, csrf_token: nil)
          @page = page
          @nonce = nonce.to_s
          @csrf_token = csrf_token
        end

        # @api private
        # @since 3.1.0
        def template_binding
          binding
        end

        # Inlined verbatim. These are our own files, never user input, so they are deliberately
        # not escaped — escaping them would break the CSS and JS.
        #
        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def stylesheet
          Renderer.asset(:stylesheet)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def javascript
          Renderer.asset(:javascript)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def icon_sprite
          Renderer.asset(:icon_sprite)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def h(value)
          # Rack::Utils rather than CGI: the cgi library is removed in Ruby 4.0, and rack is
          # already a dependency. Escapes the same five characters.
          Rack::Utils.escape_html(value.to_s)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def severity
          SEVERITIES.fetch(page.severity, "crash")
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def severity_icon
          SEVERITY_ICONS.fetch(severity)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def status_label
          [status_code, status_reason].reject(&:empty?).join(" ")
        end

        # Split from the reason so narrow screens can keep the code and drop the words.
        #
        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def status_code
          page.status.to_s
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def status_reason
          Rack::Utils::HTTP_STATUS_CODES[page.status].to_s
        end

        # @return [Array]
        #
        # @api private
        # @since 3.1.0
        def frames
          @frames ||= page.frames
        end

        # @return [Integer]
        #
        # @api private
        # @since 3.1.0
        def app_frames_count
          @app_frames_count ||= frames.count(&:app?)
        end

        # @return [Boolean]
        #
        # @api private
        # @since 3.1.0
        def app_only?
          app_frames_count.positive?
        end

        # Start on the first frame the developer wrote, not on the middleware that caught it.
        #
        # @return [Integer]
        #
        # @api private
        # @since 3.1.0
        def initial_frame_index
          @initial_frame_index ||= frames.index(&:app?) || 0
        end

        # Only a crash leads with the backtrace. When we can say something more useful, the
        # backtrace starts collapsed behind a disclosure.
        #
        # @return [Boolean]
        #
        # @api private
        # @since 3.1.0
        def collapsed?
          severity != "crash"
        end

        # @return [Object, nil]
        #
        # @api private
        # @since 3.1.0
        def presenter
          page.presenter
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def headline
          presenter&.headline || page.exception_class
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def message_html
          text_with_code_spans(presenter&.lede || page.message)
        end

        # @return [Array<String>]
        #
        # @api private
        # @since 3.1.0
        def extras
          @extras ||= trim_blanks(Array(page.detailed_extras).map { |line| line.to_s.chomp })
        end

        # `detailed_message` extras carry the error_highlight caret rows. Those get the signal
        # colour; everything else stays muted.
        #
        # @return [String]
        #
        # @api private
        # @since 3.1.0
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
        #
        # @api private
        # @since 3.1.0
        def suggestions
          @suggestions ||= Array(presenter&.suggestions)
        end

        # @return [Array<String>]
        #
        # @api private
        # @since 3.1.0
        def causes
          @causes ||= Array(page.causes)
        end

        # @return [Boolean]
        #
        # @api private
        # @since 3.1.0
        def fix?
          !!presenter && (fix_command || fix_snippet || fix_items.any? || fix_note)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def fix_title
          "Suggested fix"
        end

        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def fix_command
          presenter&.command
        end

        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def fix_snippet
          presenter&.snippet
        end

        # @return [Array<String>]
        #
        # @api private
        # @since 3.1.0
        def fix_items
          @fix_items ||= Array(presenter&.items)
        end

        # @return [String, nil]
        #
        # @api private
        # @since 3.1.0
        def fix_note
          presenter&.note
        end

        # The topbar summary. Built here, from escaped parts, so the template interpolates it whole.
        #
        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def request_summary_html
          request = page.request
          parts = ["<b>#{h(request.method_name)}</b> #{h(request.path)}"]
          parts << "slice <b>#{h(request.slice_name)}</b>" if request.slice_name
          parts << "route <b>#{h(request.route)}</b>" if request.route
          parts.join(" &middot; ")
        end

        # @return [Array<Hash>]
        #
        # @api private
        # @since 3.1.0
        def context_panels
          @context_panels ||= (presenter_panels + request_panels)
        end

        # @return [String]
        #
        # @api private
        # @since 3.1.0
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
        #
        # @api private
        # @since 3.1.0
        def payload_json
          JSON.generate(payload).gsub(/[<>&\u2028\u2029]/) { |char| format('\u%04x', char.ord) }
        end

        # Wraps quoted or backticked runs in `<code>`, the way the design shows identifiers in the
        # lede. Runs after escaping, on escaped text, so it can only ever add `<code>` tags.
        #
        # @return [String]
        #
        # @api private
        # @since 3.1.0
        def text_with_code_spans(text)
          h(text).gsub(/&#39;([^&<>]*)&#39;|`([^`&<>]*)`/) {
            "<code>#{Regexp.last_match(1) || Regexp.last_match(2)}</code>"
          }
        end

        private

        # @api private
        # @since 3.1.0
        def payload
          {
            "pageId" => page.id,
            "evalPath" => "#{MOUNT_PATH}/#{page.id}/eval",
            "csrfToken" => csrf_token,
            "csrfCookie" => CSRF_COOKIE_NAME,
            "bindingsAvailable" => Webconsole.bindings_available?,
            "initialFrame" => initial_frame_index,
            "text" => page.to_text,
            "frames" => frames.each_with_index.map { |frame, index| frame_payload(frame, index) }
          }
        end

        # @api private
        # @since 3.1.0
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

        # @api private
        # @since 3.1.0
        def trim_blanks(lines)
          lines.drop_while { |line| line.strip.empty? }
            .reverse
            .drop_while { |line| line.strip.empty? }
            .reverse
        end

        # @api private
        # @since 3.1.0
        def editor
          @editor ||= Editor.from_env
        end

        # @api private
        # @since 3.1.0
        def variables(variables)
          Array(variables).map { |variable| [variable.name, variable.class_name, variable.value] }
        end

        # @api private
        # @since 3.1.0
        def presenter_panels
          Array(presenter&.context_panels).map { |title, rows|
            panel(title.to_s, Array(rows).map { |row| Array(row) })
          }
        rescue StandardError
          []
        end

        # @api private
        # @since 3.1.0
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

        # @api private
        # @since 3.1.0
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
            .map { |(name, value)| [name, value.to_s, value.to_s == FILTERED, false] }
        end

        # @api private
        # @since 3.1.0
        def hash_rows(hash)
          hash.map { |name, value| [name.to_s, value.to_s, value.to_s == FILTERED, false] }
        end

        # @api private
        # @since 3.1.0
        def panel(title, rows)
          {
            title: title,
            icon: PANEL_ICONS.fetch(title) { PANEL_ICONS.fetch(title.split(/[\s(]/).first, "list") },
            search: searchable?(title, rows) ? "Filter #{panel_label(title)}" : nil,
            noun: panel_noun(title),
            rows: rows
          }
        end

        # @api private
        # @since 3.1.0
        def searchable?(title, rows)
          !UNSEARCHABLE_PANELS.include?(title) && rows.length >= SEARCHABLE_FROM
        end

        # "Routes (12)" filters routes, not "routes (12)".
        #
        # @api private
        # @since 3.1.0
        def panel_label(title)
          title.downcase.sub(/\s*\(.*\)\z/, "")
        end

        # @api private
        # @since 3.1.0
        def panel_noun(title)
          label = panel_label(title)
          label.match?(/\A\w+s\z/) ? label : "rows"
        end
      end
    end
  end
end
