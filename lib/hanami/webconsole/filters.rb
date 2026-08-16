# frozen_string_literal: true

module Hanami
  module Webconsole
    # Redacts sensitive values before they reach the error page.
    #
    # Matches Hanami's logger filtering: a key is filtered when its name contains one of the
    # configured keys, case-insensitively. So a filter key of `"password"` redacts `"password"`,
    # `"PASSWORD"`, `"user_password"` and `"password_confirmation"` alike.
    #
    # Filtering is applied to nested hashes and to hashes nested inside arrays, since params
    # arrive that way from the router and the body parsers.
    #
    # @api private
    # @since 3.1.0
    class Filters
      # The replacement value.
      #
      # This exact String instance is substituted, so callers can tell a redacted value from a
      # value that merely reads `"[FILTERED]"` by comparing with `equal?`. Built with `dup` so it
      # is not the deduplicated frozen literal, which a user value could also be.
      #
      # @api private
      # @since 3.1.0
      FILTERED = "[FILTERED]".dup.freeze

      # How deep to descend. Bounds the recursion for pathological or self-referential structures.
      #
      # @api private
      # @since 3.1.0
      MAX_DEPTH = 16

      # Unbound methods from the real core classes, so an object cannot escape filtering by
      # redefining `#class`, `#is_a?` or `#each_pair`. See {Inspector} for the same reasoning.
      #
      # @api private
      # @since 3.1.0
      OBJECT_CLASS = ::Object.instance_method(:class)

      # @api private
      # @since 3.1.0
      MODULE_SUBSET = ::Module.instance_method(:<=)

      # @api private
      # @since 3.1.0
      HASH_EACH_PAIR = ::Hash.instance_method(:each_pair)

      # @api private
      # @since 3.1.0
      ARRAY_MAP = ::Array.instance_method(:map)

      # @return [Array<String>] the configured keys, downcased, empties removed
      #
      # @api private
      # @since 3.1.0
      attr_reader :keys

      # @param keys [Array<String>] from `config.logger.filters`
      #
      # @api private
      # @since 3.1.0
      def initialize(keys = [])
        @keys = normalize_keys(keys)
        freeze
      end

      # Returns a copy of the hash with the values of matching keys replaced by {FILTERED}.
      #
      # @param hash [Hash]
      #
      # @return [Hash]
      #
      # @api private
      # @since 3.1.0
      def call(hash)
        return {} unless hash?(hash)

        filter_hash(hash, 0)
      end

      # @param key [Object] anything that names a value; converted to a String
      #
      # @return [Boolean]
      #
      # @api private
      # @since 3.1.0
      def filtered?(key)
        return false if keys.empty?

        name = downcased(key)
        return false if name.empty?

        keys.any? { |filtered_key| name.include?(filtered_key) }
      rescue ::Exception # rubocop:disable Lint/RescueException
        # A key we cannot even read the name of is redacted rather than shown: over-redacting is
        # recoverable, leaking a password is not.
        true
      end

      private

      # @api private
      # @since 3.1.0
      def filter_hash(hash, depth)
        result = {}

        HASH_EACH_PAIR.bind_call(hash) do |key, value|
          result[key] = filtered?(key) ? FILTERED : filter_value(value, depth + 1)
        end

        result
      end

      # @api private
      # @since 3.1.0
      def filter_value(value, depth)
        if hash?(value)
          depth > MAX_DEPTH ? FILTERED : filter_hash(value, depth)
        elsif array?(value)
          depth > MAX_DEPTH ? FILTERED : map_array(value, depth)
        else
          value
        end
      end

      # @api private
      # @since 3.1.0
      def map_array(array, depth)
        ARRAY_MAP.bind_call(array) { |element| filter_value(element, depth + 1) }
      end

      # @api private
      # @since 3.1.0
      def normalize_keys(keys)
        return [] unless array?(keys)

        ARRAY_MAP.bind_call(keys) { |key| safe_downcased(key) }.reject(&:empty?).uniq
      end

      # @api private
      # @since 3.1.0
      def safe_downcased(key)
        downcased(key)
      rescue ::Exception # rubocop:disable Lint/RescueException
        ""
      end

      # Deliberately unguarded: {#filtered?} needs to know that the name could not be read, so it
      # can fail closed.
      #
      # @api private
      # @since 3.1.0
      def downcased(key)
        name = string_for(key)

        name.valid_encoding? ? name.downcase : name.scrub("?").downcase
      end

      # Uses the real class rather than `#is_a?`, which an object is free to lie about. Filtering
      # runs over session and param values, which are arbitrary application objects.
      #
      # @api private
      # @since 3.1.0
      def hash?(object)
        kind_of_real?(object, ::Hash)
      end

      # @api private
      # @since 3.1.0
      def array?(object)
        kind_of_real?(object, ::Array)
      end

      # @api private
      # @since 3.1.0
      def kind_of_real?(object, ancestor)
        klass = OBJECT_CLASS.bind_call(object)

        MODULE_SUBSET.bind_call(klass, ancestor) ? true : false
      rescue ::Exception # rubocop:disable Lint/RescueException
        false
      end

      # @api private
      # @since 3.1.0
      def string_for(key)
        return key if kind_of_real?(key, ::String)

        name = key.to_s
        kind_of_real?(name, ::String) ? name : ""
      end
    end
  end
end
