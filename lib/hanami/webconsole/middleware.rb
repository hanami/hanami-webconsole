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
    # @since 3.1.0
    class Middleware
      # The set of IP addresses allowed to see the error page and reach the console.
      #
      # @api private
      # @since 3.1.0
      ALLOWED_IPS = Set.new

      # Adds an address or subnet to {ALLOWED_IPS}.
      #
      # @param addr [String, IPAddr]
      #
      # @api private
      # @since 3.1.0
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
      #
      # @api private
      # @since 3.1.0
      CSRF_TOKEN_COOKIE_NAME = Webconsole::CSRF_COOKIE_NAME

      # Path of the console's internal endpoints.
      #
      # Built from the shared mount path, so the template and the middleware cannot drift.
      #
      # @api private
      # @since 3.1.0
      INTERNAL_PATH = %r{
        \A#{Regexp.escape(Webconsole::MOUNT_PATH)}
        /(?<id>[A-Za-z0-9_-]+)
        /(?<action>variables|eval|resolve)\z
      }x

      # Serialises resolution runs across threads. See {#resolve_response}.
      #
      # @api private
      # @since 3.1.0
      RESOLUTION_LOCK = Mutex.new

      # @api private
      # @since 3.1.0
      HTML_CONTENT_TYPE = "text/html; charset=utf-8"

      # @api private
      # @since 3.1.0
      TEXT_CONTENT_TYPE = "text/plain; charset=utf-8"

      # @api private
      # @since 3.1.0
      JSON_CONTENT_TYPE = "application/json; charset=utf-8"

      # @api private
      # @since 3.1.0
      def initialize(app, config)
        @app = app
        @config = config
        @registry = Registry.new
      end

      # @api private
      # @since 3.1.0
      def call(env)
        # Deliberately first, and deliberately before the internal endpoints: a non-allowed
        # address must not be able to tell this middleware apart from its absence.
        return @app.call(env) unless allow_ip?(env)

        match = INTERNAL_PATH.match(env["PATH_INFO"].to_s)
        return internal_call(Rack::Request.new(env), match[:id], match[:action]) if match

        app_call(env)
      end

      private

      # @api private
      # @since 3.1.0
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
      #
      # @api private
      # @since 3.1.0
      def allow_ip?(env)
        ip = Rack::Request.new(env).ip
        return true if ip.nil? || ip.strip.empty?

        address = IPAddr.new(ip.split("%").first)
        ALLOWED_IPS.any? { |subnet| subnet.include?(address) }
      rescue ArgumentError # IPAddr::InvalidAddressError is an ArgumentError
        false
      end

      # @api private
      # @since 3.1.0
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
      #
      # @api private
      # @since 3.1.0
      def negotiate(request, page, csrf_token, csp_nonce)
        if json?(request)
          [JSON_CONTENT_TYPE, Renderer.render_json(page)]
        elsif text?(request)
          [TEXT_CONTENT_TYPE, Renderer.render_text(page)]
        else
          [HTML_CONTENT_TYPE, Renderer.render_html(page, nonce: csp_nonce, csrf_token: csrf_token)]
        end
      end

      # @api private
      # @since 3.1.0
      def json?(request)
        accept(request).start_with?("application/json")
      end

      # Ported verbatim from better_errors.
      #
      # @api private
      # @since 3.1.0
      def text?(request)
        request.get_header("HTTP_X_REQUESTED_WITH") == "XMLHttpRequest" ||
          !accept(request).include?("html")
      end

      # @api private
      # @since 3.1.0
      def accept(request)
        request.get_header("HTTP_ACCEPT").to_s.strip
      end

      # @api private
      # @since 3.1.0
      def content_security_policy(nonce)
        [
          "default-src 'none'",
          "script-src 'nonce-#{nonce}'",
          "style-src 'nonce-#{nonce}'",
          "img-src data:",
          "connect-src 'self'"
        ].join("; ")
      end

      # @api private
      # @since 3.1.0
      def build_page(env, exception)
        ErrorPage.new(
          exception: exception,
          env: env,
          config: @config,
          id: "#{Webconsole.generation}-#{SecureRandom.hex(8)}",
          generation: Webconsole.generation,
          bindings: bindings_for(exception)
        )
      end

      # Bindings are captured at raise time by {ExceptionExtension}. Without them there are no
      # local variables and no console, but the page still renders.
      #
      # @api private
      # @since 3.1.0
      def bindings_for(exception)
        return nil unless exception.respond_to?(:__hanami_webconsole_bindings)

        bindings = exception.__hanami_webconsole_bindings
        bindings.empty? ? nil : bindings
      rescue StandardError
        nil
      end

      # This is what the `BetterErrors::Middleware#show_error_page` monkey patch existed to do:
      # better_errors hardcoded 500 outside Rails, so the status had to be corrected afterwards.
      #
      # @api private
      # @since 3.1.0
      def status_for(exception)
        response = @config.render_error_responses[exception.class.name]
        return 500 unless response

        Rack::Utils.status_code(response)
      rescue StandardError
        500
      end

      # Requests that reach here have already cleared the IP allowlist.
      #
      # @api private
      # @since 3.1.0
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
        when "resolve" then resolve_response(page, body, request)
        else json_response(404, error: "Not found", explanation: "Not a recognized console call.")
        end
      end

      # @api private
      # @since 3.1.0
      def json_body?(request)
        request.media_type == "application/json"
      end

      # @api private
      # @since 3.1.0
      def parse_body(request)
        request.body.rewind if request.body.respond_to?(:rewind)
        parsed = JSON.parse(request.body.read.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      # The cookie is `httponly` and `same_site: :strict`, so a cross-site page can neither read
      # the token nor cause the browser to send the cookie. Compared in constant time.
      #
      # @api private
      # @since 3.1.0
      def valid_csrf?(request, body)
        cookie = request.cookies[CSRF_TOKEN_COOKIE_NAME]
        token = body["csrfToken"]

        return false unless cookie.is_a?(String) && !cookie.empty?
        return false unless token.is_a?(String) && !token.empty?

        Rack::Utils.secure_compare(cookie, token)
      end

      # @api private
      # @since 3.1.0
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

      # Runs one of the resolutions the error offered.
      #
      # Resolutions are addressed by their index in the error's own list, never by anything the
      # request supplies, so this endpoint cannot be talked into running arbitrary code — only
      # something the raised error already published.
      #
      # @api private
      # @since 3.1.0
      def resolve_response(page, body, request)
        index = body["index"]
        resolution = page.resolutions[index] if index.is_a?(::Integer) && index >= 0

        unless resolution
          return json_response(
            404, error: "Unknown resolution",
            explanation: "This error does not offer a resolution at that position."
          )
        end

        # One at a time. A resolution migrates a database or rewrites files, and Puma is
        # threaded: two of these interleaving would be worse than making the second one wait.
        result = RESOLUTION_LOCK.synchronize { resolution.call(resolution_context(request)) }

        json_response(
          200,
          id: page.id, index: index, name: resolution.name,
          ok: result.ok?, output: result.output
        )
      end

      # @api private
      # @since 3.1.0
      def resolution_context(request)
        Resolution::Context.new(
          app: (Hanami.app if defined?(Hanami.app)),
          slice: request.get_header("hanami.slice"),
          request: request
        )
      rescue StandardError
        Resolution::Context.new(app: nil, slice: nil, request: request)
      end

      # @api private
      # @since 3.1.0
      def eval_response(page, body)
        frame = frame_for(page, body)
        return unknown_frame_response unless frame

        source = body["source"].to_s

        unless frame.binding
          return json_response(
            200,
            id: page.id, index: frame_index(body), source: source, error: true,
            output: "The console is unavailable for this frame."
          )
        end

        # `output` rather than `result`: it is the key the template's `evaluate()` reads.
        output, error = Repl::Session.new(frame.binding).eval(source)

        json_response(
          200,
          id: page.id, index: frame_index(body), source: source,
          output: output.to_s, error: !!error
        )
      end

      # @api private
      # @since 3.1.0
      def variable_payload(variable)
        {name: variable.name, className: variable.class_name, value: variable.value}
      end

      # @api private
      # @since 3.1.0
      def frame_index(body)
        index = Integer(body["index"], exception: false)
        return nil if index.nil? || index.negative?

        index
      end

      # @api private
      # @since 3.1.0
      def frame_for(page, body)
        index = frame_index(body)
        return nil unless index

        page.frames[index]
      end

      # @api private
      # @since 3.1.0
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
      #
      # @api private
      # @since 3.1.0
      def expired_response
        json_response(
          410,
          error: "Session expired",
          explanation: "This error page was captured before the last code reload, so its " \
                       "console session no longer exists. Refresh the page to start a new one.",
          action: "refresh"
        )
      end

      # @api private
      # @since 3.1.0
      def invalid_csrf_response
        json_response(
          403,
          error: "Invalid CSRF token",
          explanation: "The browser session might have been cleared. Refresh the page and " \
                       "try again."
        )
      end

      # @api private
      # @since 3.1.0
      def json_response(status, payload)
        [status, {"content-type" => JSON_CONTENT_TYPE}, [JSON.generate(payload)]]
      end

      # Last resort: the error page itself blew up. Never let that hide the original exception.
      #
      # @api private
      # @since 3.1.0
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
