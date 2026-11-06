# frozen_string_literal: true

require "rack"

require_relative "filters"
require_relative "inspector"
require_relative "safety"

module Hanami
  module Webconsole
    # The request, prepared for display.
    #
    # Everything here is already a String and already filtered: the template does no formatting
    # and no redacting of its own. Nothing raises. A Rack env is only loosely specified, the
    # request may be half-built at the point the exception was raised, and lazy objects in it
    # (a session store, a parsed body) may raise the moment they are touched — so every reader
    # degrades to `{}` or `""` rather than taking the error page down with it.
    #
    # @api private
    class RequestContext
      include Safety

      # Env keys, other than the `HTTP_*` ones, that are request headers.
      HEADER_KEYS = {"CONTENT_TYPE" => "Content-Type", "CONTENT_LENGTH" => "Content-Length"}.freeze

      HTTP_PREFIX = "HTTP_"

      SESSION_KEY = "rack.session"

      ANY_MEDIA_TYPE = "*/*"

      # @return [Hash] the Rack env
      attr_reader :env

      # @return [Filters]
      attr_reader :filters

      # @param env [Hash] the Rack env
      # @param filters [Filters]
      def initialize(env:, filters: Filters.new)
        @env = env.is_a?(::Hash) ? env : {}
        @filters = filters || Filters.new
        @request = build_request
      end

      # @return [String] e.g. `"GET"`
      def method_name
        @method_name ||= string(safely(nil) { request&.request_method })
      end

      # @return [String] e.g. `"/books/247"`
      def path
        @path ||= string(safely(nil) { request&.path })
      end

      # The media type the response was being negotiated for, falling back to the media type of
      # the request body.
      #
      # @return [String] e.g. `"text/html"`, `""` when unknown
      def format
        @format ||= accepted_media_type || media_type(env["CONTENT_TYPE"]) || ""
      end

      # @return [String] e.g. `"127.0.0.1"`
      def ip
        @ip ||= string(safely(nil) { request&.ip })
      end

      # @return [Hash<String, String>] filtered, values inspected
      def params
        @params ||= presentable(safely(nil) { request&.params } || {})
      end

      # @return [Hash<String, String>] filtered, values inspected, `{}` when there is no session
      def session
        @session ||= presentable(session_hash)
      end

      # @return [Hash<String, String>] filtered
      def cookies
        @cookies ||= redacted(safely(nil) { request&.cookies } || {})
      end

      # Request headers, `HTTP_` de-prefixed and title-cased: `HTTP_ACCEPT_LANGUAGE` becomes
      # `"Accept-Language"`.
      #
      # @return [Hash<String, String>] filtered, sorted by name
      def headers
        @headers ||= redacted(raw_headers)
      end

      private

      # @return [Rack::Request, nil]
      attr_reader :request

      def build_request
        ::Rack::Request.new(env)
      rescue *ERRORS
        nil
      end

      def raw_headers
        headers = {}

        env.each_key do |key|
          name = header_name(key)
          next unless name

          headers[name] = string(env[key])
        end

        headers.sort.to_h
      rescue *ERRORS
        {}
      end

      def header_name(key)
        return nil unless key.is_a?(::String)
        return HEADER_KEYS[key] if HEADER_KEYS.key?(key)
        return nil unless key.start_with?(HTTP_PREFIX)

        name = key[HTTP_PREFIX.length..].to_s
        return nil if name.empty?

        name.split("_").map { |part| part.capitalize }.join("-")
      end

      def session_hash
        raw = safely(nil) { env[SESSION_KEY] }
        return {} if raw.nil?

        hash = safely(nil) { raw.to_hash if raw.respond_to?(:to_hash) }
        hash.is_a?(::Hash) ? hash : {}
      end

      # Filters a hash and renders every value with {Inspector}, leaving the redaction marker
      # itself untouched.
      def presentable(hash)
        redacted(hash) { |value| Inspector.call(value) }
      end

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
      rescue *ERRORS
        {}
      end

      def accepted_media_type
        accepted = media_type(env["HTTP_ACCEPT"].to_s.split(",").first)
        return nil if accepted.nil? || accepted == ANY_MEDIA_TYPE

        accepted
      rescue *ERRORS
        nil
      end

      def media_type(value)
        type = string(value).split(";").first.to_s.strip.downcase
        type.empty? ? nil : type
      rescue *ERRORS
        nil
      end

      def string(value)
        return "" if value.nil?
        return Inspector.call(value) unless value.is_a?(::String) || value.is_a?(::Symbol)

        utf8(value.to_s)
      rescue *ERRORS
        ""
      end

      # Header, cookie and param strings come off the wire and can hold any bytes at all. They go
      # straight into an HTML document, so they must be valid UTF-8 before they get there.
      def utf8(value)
        value = value.encode(::Encoding::UTF_8, invalid: :replace, undef: :replace) unless
          value.encoding == ::Encoding::UTF_8

        value.valid_encoding? ? value : value.scrub("?")
      rescue *ERRORS
        ""
      end
    end
  end
end
