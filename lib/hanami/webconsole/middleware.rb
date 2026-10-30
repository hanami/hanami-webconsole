# frozen_string_literal: true

require "ipaddr"
require "json"
require "rack"
require "securerandom"

# rubocop:disable Lint/RescueException

module Hanami
  module Webconsole
    # Rescues exceptions raised below it and renders the development error page.
    #
    # The security model is ported from better_errors, which this replaces. Three controls, in
    # this order:
    #
    # 1. An IP allowlist, checked before anything else. A request from a non-allowed address is
    #    passed straight to the app: no error page, no internal endpoints, no way to tell from
    #    the outside that this middleware is even installed.
    # 2. A CSRF token in an `httponly`, `same_site: :strict` cookie, which every request to the
    #    console endpoints must echo back in its JSON body.
    # 3. A strict `Content-Security-Policy` with a per-response nonce, so the inline script and
    #    style in the page are the only ones the browser will run.
    #
    # The console endpoints evaluate arbitrary Ruby in a captured `Binding`. Treat any change
    # to the order above as a change to that exposure.
    #
    # @api private
    class Middleware
      # The set of IP addresses allowed to see the error page and reach the console.
      ALLOWED_IPS = Set.new

      # Adds an address or subnet to {ALLOWED_IPS}.
      #
      # @param addr [String, IPAddr]
      def self.allow_ip!(addr)
        ALLOWED_IPS << (addr.is_a?(IPAddr) ? addr : IPAddr.new(addr))
      end

      allow_ip! "127.0.0.0/8"
      begin
        allow_ip! "::1/128"
      rescue StandardError
        # Some builds (historically, Windows Ruby) have no IPv6 support.
        nil
      end

      # Name of the CSRF cookie.
      #
      # Unlike better_errors, this carries no gem version: the version served only to invalidate
      # the cookie across upgrades, and generation-scoped page ids already handle staleness.
      CSRF_TOKEN_COOKIE_NAME = Webconsole::CSRF_COOKIE_NAME

      # Path of the console's internal endpoints.
      #
      # Built from the shared mount path, so the template and the middleware cannot drift.
      INTERNAL_PATH = %r{
        \A#{Regexp.escape(Webconsole::MOUNT_PATH)}
        /(?<id>[A-Za-z0-9_-]+)
        /(?<action>variables|eval|run)\z
      }x

      # The lock that makes fixes run one at a time, across all threads and browser tabs.
      #
      # See {#with_run_lock}.
      RUN_LOCK = Mutex.new

      HTML_CONTENT_TYPE = "text/html; charset=utf-8"

      TEXT_CONTENT_TYPE = "text/plain; charset=utf-8"

      JSON_CONTENT_TYPE = "application/json; charset=utf-8"

      # @param app [#call] the Rack app below
      # @param slice [Hanami::Slice] the slice this middleware belongs to. Its config gives the
      #   error responses, the root and the logger's filters, and diagnostics get the slice itself.
      def initialize(app, slice)
        @app = app
        @slice = slice
        @config = slice.config
        @registry = Registry.new
      end

      def call(env)
        # Deliberately first, and deliberately before the internal endpoints: a non-allowed
        # address must not be able to tell this middleware apart from its absence.
        return @app.call(env) unless allow_ip?(env)

        match = INTERNAL_PATH.match(env["PATH_INFO"].to_s)
        return internal_call(Rack::Request.new(env), match[:id], match[:action]) if match

        app_call(env)
      end

      private

      def app_call(env)
        @app.call(env)
      rescue Exception => exception
        begin
          render_error_page(env, exception)
        rescue Exception => rendering_exception
          fallback_response(exception, rendering_exception)
        end
      end

      # Ported from better_errors, including its two quirks: a blank or missing `REMOTE_ADDR` is
      # allowed (some servers do not set one), and an IPv6 zone id is stripped before parsing.
      #
      # Unlike better_errors, an unparseable address is denied rather than raised out of the
      # middleware.
      def allow_ip?(env)
        ip = Rack::Request.new(env).ip
        return true if ip.nil? || ip.strip.empty?

        address = IPAddr.new(ip.split("%").first)
        ALLOWED_IPS.any? { |subnet| subnet.include?(address) }
      rescue ArgumentError # IPAddr::InvalidAddressError is an ArgumentError
        false
      end

      def render_error_page(env, exception)
        request = Rack::Request.new(env)
        page = build_page(env, exception)
        @registry.put(page)

        status = status_for(exception)
        csrf_token = request.cookies[CSRF_TOKEN_COOKIE_NAME] || SecureRandom.uuid
        csp_nonce = SecureRandom.base64(12)

        content_type, body = negotiate(request, page, csrf_token, csp_nonce)

        headers = {
          "content-type" => content_type,
          "content-security-policy" => content_security_policy(csp_nonce)
        }

        response = Rack::Response.new(body, status, headers)
        unless request.cookies[CSRF_TOKEN_COOKIE_NAME]
          response.set_cookie(
            CSRF_TOKEN_COOKIE_NAME,
            value: csrf_token, path: "/", httponly: true, same_site: :strict
          )
        end

        (_status, headers, _body) = response.finish
        [status, headers, [body]]
      end

      # `Accept: application/json` is checked first: a JSON `Accept` header also lacks "html",
      # so the plain text branch would otherwise swallow it.
      def negotiate(request, page, csrf_token, csp_nonce)
        if json?(request)
          [JSON_CONTENT_TYPE, Rendering::JSON.new(page).to_s]
        elsif text?(request)
          [TEXT_CONTENT_TYPE, Rendering::Markdown.new(page).to_s]
        else
          [HTML_CONTENT_TYPE, Rendering::HTML.new(page, nonce: csp_nonce, csrf_token:).to_s]
        end
      end

      def json?(request)
        accept(request).start_with?("application/json")
      end

      # Ported verbatim from better_errors.
      def text?(request)
        request.get_header("HTTP_X_REQUESTED_WITH") == "XMLHttpRequest" ||
          !accept(request).include?("html")
      end

      def accept(request)
        request.get_header("HTTP_ACCEPT").to_s.strip
      end

      def content_security_policy(nonce)
        [
          "default-src 'none'",
          "script-src 'nonce-#{nonce}'",
          "style-src 'nonce-#{nonce}'",
          "img-src data:",
          "connect-src 'self'"
        ].join("; ")
      end

      # The page stamps itself with the current generation, and makes its id from it (see
      # {ErrorPage.generate_id}).
      def build_page(env, exception)
        ErrorPage.new(
          exception:,
          env:,
          config: @config,
          bindings: bindings_for(exception),
          slice: @slice
        )
      end

      # Bindings are captured at raise time by {ExceptionExtension}. Without them there are no
      # local variables and no console, but the page still renders.
      def bindings_for(exception)
        return nil unless exception.respond_to?(:__hanami_webconsole_bindings)

        bindings = exception.__hanami_webconsole_bindings
        bindings.empty? ? nil : bindings
      rescue StandardError
        nil
      end

      # This is what the `BetterErrors::Middleware#show_error_page` monkey patch existed to do:
      # better_errors hardcoded 500 outside Rails, so the status had to be corrected afterwards.
      def status_for(exception)
        response = @config.render_error_responses[exception.class.name]
        return 500 unless response

        Rack::Utils.status_code(response)
      rescue StandardError
        500
      end

      # Requests that reach here have already cleared the IP allowlist.
      def internal_call(request, id, action)
        unless request.post?
          return json_response(
            405, error: "Method not allowed", explanation: "Console endpoints accept POST only."
          )
        end

        unless json_body?(request)
          return json_response(
            406, error: "Not acceptable",
            explanation: "Console endpoints accept application/json only."
          )
        end

        body = parse_body(request)
        unless body
          return json_response(
            400, error: "Malformed request", explanation: "The request body was not valid JSON."
          )
        end

        # CSRF before the id lookup, so a cross-origin request cannot probe which ids exist.
        return invalid_csrf_response unless valid_csrf?(request, body)

        page = @registry.fetch(id)
        return expired_response unless page

        case action
        when "variables" then variables_response(page, body)
        when "eval" then eval_response(page, body)
        when "run" then run_response(page)
        else json_response(404, error: "Not found", explanation: "Not a recognized console call.")
        end
      end

      def json_body?(request)
        request.media_type == "application/json"
      end

      def parse_body(request)
        request.body.rewind if request.body.respond_to?(:rewind)
        parsed = JSON.parse(request.body.read.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      # The cookie is `httponly` and `same_site: :strict`, so a cross-site page can neither read
      # the token nor cause the browser to send the cookie. Compared in constant time.
      def valid_csrf?(request, body)
        cookie = request.cookies[CSRF_TOKEN_COOKIE_NAME]
        token = body["csrfToken"]

        return false unless cookie.is_a?(String) && !cookie.empty?
        return false unless token.is_a?(String) && !token.empty?

        Rack::Utils.secure_compare(cookie, token)
      end

      def variables_response(page, body)
        frame = frame_for(page, body)
        return unknown_frame_response unless frame

        json_response(
          200,
          id: page.id,
          index: frame_index(body),
          replAvailable: Webconsole.bindings_available? && !frame.binding.nil?,
          receiver: frame.receiver_inspect,
          locals: frame.locals.map { |variable| variable_payload(variable) },
          instanceVariables: frame.instance_vars.map { |variable| variable_payload(variable) }
        )
      end

      # Runs the fix offered by the page's diagnostic, and returns the result as a JSON response.
      #
      # A page has at most one fix, and it belongs to the same diagnostic that rendered the page.
      # The request doesn't choose anything, so this endpoint can't be made to run arbitrary code.
      # It can only run the fix that the error already offered.
      #
      # @param page [ErrorPage]
      #
      # @return [Array] a Rack response
      def run_response(page)
        diagnostic = page.diagnostic

        unless diagnostic&.runnable_fix?
          return json_response(
            404, error: "No fix to run", explanation: "This error doesn't offer a fix that can run."
          )
        end

        result = with_run_lock { diagnostic.run_fix }

        unless result
          return json_response(
            409, error: "Busy", explanation: "Another fix is still running. Try again when it finishes."
          )
        end

        json_response(200, id: page.id, name: diagnostic.fix.name, ok: result.ok?, output: result.output)
      end

      # Calls the given block while holding the lock for running fixes.
      #
      # This makes sure fixes run one at a time. A fix may change the database or write files, and
      # since Puma is threaded, two fixes running at once would be worse than making the second one
      # fail.
      #
      # If another fix is already running, this returns nil at once rather than waiting. Fixes are
      # safe to run twice, so a request that waited would most often just repeat the work. Not
      # waiting also means a fix that hangs doesn't leave every later click hanging too.
      #
      # @yieldreturn [Object]
      #
      # @return [Object, nil] the block's result, or nil if another fix is running
      def with_run_lock
        return nil unless RUN_LOCK.try_lock

        begin
          yield
        ensure
          RUN_LOCK.unlock
        end
      end

      def eval_response(page, body)
        frame = frame_for(page, body)
        return unknown_frame_response unless frame

        source = body["source"].to_s

        unless frame.binding
          return json_response(
            200,
            id: page.id, index: frame_index(body), source:, error: true,
            output: "The console is unavailable for this frame."
          )
        end

        # `output` rather than `result`: it is the key the template's `evaluate()` reads.
        output, error = Repl::Session.new(frame.binding).eval(source)

        json_response(
          200,
          id: page.id, index: frame_index(body), source:,
          output: output.to_s, error: !!error
        )
      end

      def variable_payload(variable)
        {name: variable.name, className: variable.class_name, value: variable.value}
      end

      def frame_index(body)
        index = Integer(body["index"], exception: false)
        return nil if index.nil? || index.negative?

        index
      end

      def frame_for(page, body)
        index = frame_index(body)
        return nil unless index

        page.frames[index]
      end

      def unknown_frame_response
        json_response(
          404,
          error: "Unknown frame",
          explanation: "That backtrace frame is not part of this error page."
        )
      end

      # A page from an earlier generation is gone for good: its bindings refer to constants the
      # reloader has since unloaded. 410 rather than 404 says so precisely, and the page uses it
      # to show its "refresh to continue" state.
      def expired_response
        json_response(
          410,
          error: "Session expired",
          explanation: "This error page was captured before the last code reload, so its " \
                       "console session no longer exists. Refresh the page to start a new one.",
          action: "refresh"
        )
      end

      def invalid_csrf_response
        json_response(
          403,
          error: "Invalid CSRF token",
          explanation: "The browser session might have been cleared. Refresh the page and " \
                       "try again."
        )
      end

      def json_response(status, payload)
        [status, {"content-type" => JSON_CONTENT_TYPE}, [JSON.generate(payload)]]
      end

      # Last resort: the error page itself blew up. Never let that hide the original exception.
      def fallback_response(exception, rendering_exception)
        body = <<~TEXT
          #{exception.class}: #{exception.message}

          Hanami::Webconsole could not render its error page for this exception:
          #{rendering_exception.class}: #{rendering_exception.message}
          #{Array(rendering_exception.backtrace).first(10).join("\n")}
        TEXT

        [500, {"content-type" => TEXT_CONTENT_TYPE}, [body]]
      end
    end
  end
end

# rubocop:enable Lint/RescueException
