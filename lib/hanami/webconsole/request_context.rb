# frozen_string_literal: true

require "rack"

require_relative "filters"
require_relative "inspector"

module Hanami
  module Webconsole
    # The request, prepared for display.
    #
    # Everything here is already a String and already filtered: the template does no formatting
    # and no redacting of its own. Nothing raises. A Rack env is only loosely specified, the
    # request may be half-built at the point the exception was raised, and lazy objects in it
    # (a session store, a parsed body) may raise the moment they are touched — so every reader
    # degrades to `{}`, `""` or `nil` rather than taking the error page down with it.
    #
    # The Hanami-specific readers ({#slice_name}, {#route}, {#action_name}) read env keys that
    # only exist when the request went through Hanami's router and actions. Against a bare Rack
    # env they return `nil`.
    #
    # @api private
    # @since 3.1.0
    class RequestContext
      # Env keys carrying the slice that handled the request.
      #
      # @api private
      # @since 3.1.0
      SLICE_KEYS = ["hanami.slice", "hanami.slice_name"].freeze

      # Env keys carrying the action instance or class.
      #
      # @api private
      # @since 3.1.0
      ACTION_KEYS = ["hanami.action_instance", "hanami.action", "hanami.action_name"].freeze

      # Env keys carrying the matched route.
      #
      # @api private
      # @since 3.1.0
      ROUTE_KEYS = ["hanami.route", "router.route"].freeze

      # Env keys, other than the `HTTP_*` ones, that are request headers.
      #
      # @api private
      # @since 3.1.0
      HEADER_KEYS = {"CONTENT_TYPE" => "Content-Type", "CONTENT_LENGTH" => "Content-Length"}.freeze

      # @api private
      # @since 3.1.0
      HTTP_PREFIX = "HTTP_"

      # @api private
      # @since 3.1.0
      SESSION_KEY = "rack.session"

      # @api private
      # @since 3.1.0
      ANY_MEDIA_TYPE = "*/*"

      # @return [Hash] the Rack env
      #
      # @api private
      # @since 3.1.0
      attr_reader :env

      # @return [Filters]
      #
      # @api private
      # @since 3.1.0
      attr_reader :filters

      # @param env [Hash] the Rack env
      # @param filters [Filters]
      #
      # @api private
      # @since 3.1.0
      def initialize(env:, filters: Filters.new)
        @env = env.is_a?(::Hash) ? env : {}
        @filters = filters || Filters.new
        @request = build_request
      end

      # @return [String] e.g. `"GET"`
      #
      # @api private
      # @since 3.1.0
      def method_name
        @method_name ||= string(safely { request&.request_method })
      end

      # @return [String] e.g. `"/books/247"`
      #
      # @api private
      # @since 3.1.0
      def path
        @path ||= string(safely { request&.path })
      end

      # The media type the response was being negotiated for, falling back to the media type of
      # the request body.
      #
      # @return [String] e.g. `"text/html"`, `""` when unknown
      #
      # @api private
      # @since 3.1.0
      def format
        @format ||= accepted_media_type || media_type(env["CONTENT_TYPE"]) || ""
      end

      # @return [String] e.g. `"127.0.0.1"`
      #
      # @api private
      # @since 3.1.0
      def ip
        @ip ||= string(safely { request&.ip })
      end

      # @return [Hash<String, String>] filtered, values inspected
      #
      # @api private
      # @since 3.1.0
      def params
        @params ||= presentable(safely { request&.params } || {})
      end

      # @return [Hash<String, String>] filtered, values inspected, `{}` when there is no session
      #
      # @api private
      # @since 3.1.0
      def session
        @session ||= presentable(session_hash)
      end

      # @return [Hash<String, String>] filtered
      #
      # @api private
      # @since 3.1.0
      def cookies
        @cookies ||= redacted(safely { request&.cookies } || {})
      end

      # Request headers, `HTTP_` de-prefixed and title-cased: `HTTP_ACCEPT_LANGUAGE` becomes
      # `"Accept-Language"`.
      #
      # @return [Hash<String, String>] filtered, sorted by name
      #
      # @api private
      # @since 3.1.0
      def headers
        @headers ||= redacted(raw_headers)
      end

      # @return [String, nil] e.g. `"main"`
      #
      # @api private
      # @since 3.1.0
      def slice_name
        return @slice_name if defined?(@slice_name)

        @slice_name = build_slice_name
      end

      # @return [String, nil] e.g. `"GET /books/:id → books.show"`
      #
      # @api private
      # @since 3.1.0
      def route
        return @route if defined?(@route)

        @route = build_route
      end

      # @return [String, nil] e.g. `"Bookshelf::Actions::Books::Show"`
      #
      # @api private
      # @since 3.1.0
      def action_name
        return @action_name if defined?(@action_name)

        @action_name = build_action_name
      end

      private

      # @return [Rack::Request, nil]
      #
      # @api private
      # @since 3.1.0
      attr_reader :request

      # @api private
      # @since 3.1.0
      def build_request
        ::Rack::Request.new(env)
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end

      # @api private
      # @since 3.1.0
      def raw_headers
        headers = {}

        env.each_key do |key|
          name = header_name(key)
          next unless name

          headers[name] = string(env[key])
        end

        headers.sort.to_h
      rescue ::Exception # rubocop:disable Lint/RescueException
        {}
      end

      # @api private
      # @since 3.1.0
      def header_name(key)
        return nil unless key.is_a?(::String)
        return HEADER_KEYS[key] if HEADER_KEYS.key?(key)
        return nil unless key.start_with?(HTTP_PREFIX)

        name = key[HTTP_PREFIX.length..].to_s
        return nil if name.empty?

        name.split("_").map { |part| part.capitalize }.join("-")
      end

      # @api private
      # @since 3.1.0
      def session_hash
        raw = safely { env[SESSION_KEY] }
        return {} if raw.nil?

        hash = safely { raw.to_hash if raw.respond_to?(:to_hash) }
        hash.is_a?(::Hash) ? hash : {}
      end

      # Filters a hash and renders every value with {Inspector}, leaving the redaction marker
      # itself untouched.
      #
      # @api private
      # @since 3.1.0
      def presentable(hash)
        redacted(hash) { |value| Inspector.call(value) }
      end

      # @api private
      # @since 3.1.0
      def redacted(hash)
        result = {}

        filters.call(hash).each_pair do |key, value|
          name = string(key)
          result[name] = if value.equal?(Filters::FILTERED)
                           value
                         elsif block_given?
                           yield(value)
                         else
                           string(value)
                         end
        end

        result
      rescue ::Exception # rubocop:disable Lint/RescueException
        {}
      end

      # @api private
      # @since 3.1.0
      def build_slice_name
        value = hanami_value(SLICE_KEYS)
        return nil if value.nil?

        name = safely { value.slice_name.to_s if value.respond_to?(:slice_name) }
        name = module_or_scalar_name(value) if blank?(name)

        presence(name)
      end

      # @api private
      # @since 3.1.0
      def build_action_name
        value = hanami_value(ACTION_KEYS)
        return nil if value.nil?

        name = module_or_scalar_name(value)
        # An action instance: its class name is what identifies it.
        name = Inspector.class_name(value) if blank?(name)

        presence(name)
      end

      # @api private
      # @since 3.1.0
      def build_route
        value = hanami_value(ROUTE_KEYS)
        return nil if value.nil?

        presence(scalar_name(value) || route_from(value))
      end

      # Formats a route object duck-typed on `Hanami::Router::Route`: `#http_method`, `#path`,
      # and `#as` or `#to` for the endpoint.
      #
      # @api private
      # @since 3.1.0
      def route_from(value)
        pattern = safely { value.path if value.respond_to?(:path) }
        return nil if blank?(pattern)

        verb = route_verb(value)
        endpoint = route_endpoint(value)

        formatted = +""
        formatted << "#{verb} " if verb
        formatted << string(pattern)
        formatted << " → #{endpoint}" if endpoint
        formatted
      end

      # @api private
      # @since 3.1.0
      def route_verb(value)
        verb = safely { value.http_method if value.respond_to?(:http_method) }

        blank?(verb) ? nil : string(verb)
      end

      # @api private
      # @since 3.1.0
      def route_endpoint(value)
        endpoint = safely { value.as if value.respond_to?(:as) }
        endpoint = safely { value.to if value.respond_to?(:to) } if blank?(endpoint)

        blank?(endpoint) ? nil : endpoint_name(endpoint)
      end

      # @api private
      # @since 3.1.0
      def endpoint_name(endpoint)
        module_or_scalar_name(endpoint) || Inspector.class_name(endpoint)
      end

      # @api private
      # @since 3.1.0
      def module_or_scalar_name(value)
        name = safely { value.name if value.is_a?(::Module) }
        return string(name) unless blank?(name)

        scalar_name(value)
      end

      # @api private
      # @since 3.1.0
      def scalar_name(value)
        return string(value) if value.is_a?(::String) || value.is_a?(::Symbol)

        nil
      end

      # Returns the first present value among `keys`, or nil.
      #
      # @api private
      # @since 3.1.0
      def hanami_value(keys)
        keys.each do |key|
          value = safely { env[key] }
          return value unless value.nil?
        end

        nil
      end

      # @api private
      # @since 3.1.0
      def accepted_media_type
        accepted = media_type(env["HTTP_ACCEPT"].to_s.split(",").first)
        return nil if accepted.nil? || accepted == ANY_MEDIA_TYPE

        accepted
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end

      # @api private
      # @since 3.1.0
      def media_type(value)
        type = string(value).split(";").first.to_s.strip.downcase
        type.empty? ? nil : type
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end

      # @api private
      # @since 3.1.0
      def string(value)
        return "" if value.nil?
        return Inspector.call(value) unless value.is_a?(::String) || value.is_a?(::Symbol)

        utf8(value.to_s)
      rescue ::Exception # rubocop:disable Lint/RescueException
        ""
      end

      # Header, cookie and param strings come off the wire and can hold any bytes at all. They go
      # straight into an HTML document, so they must be valid UTF-8 before they get there.
      #
      # @api private
      # @since 3.1.0
      def utf8(value)
        value = value.encode(::Encoding::UTF_8, invalid: :replace, undef: :replace) unless
          value.encoding == ::Encoding::UTF_8

        value.valid_encoding? ? value : value.scrub("?")
      rescue ::Exception # rubocop:disable Lint/RescueException
        ""
      end

      # @api private
      # @since 3.1.0
      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      rescue ::Exception # rubocop:disable Lint/RescueException
        true
      end

      # @api private
      # @since 3.1.0
      def presence(value)
        name = string(value)
        name.empty? ? nil : name
      end

      # @api private
      # @since 3.1.0
      def safely
        yield
      rescue ::Exception # rubocop:disable Lint/RescueException
        nil
      end
    end
  end
end
