# frozen_string_literal: true

module Hanami
  module Webconsole
    # Safe replacement for `#inspect`.
    #
    # Every value rendered on the error page passes through here. The page runs in a development
    # server against whatever objects the application happens to have in scope, so this must be
    # hostile-input safe: `#inspect` may raise anything (including non-`StandardError`), return a
    # non-String, recurse forever, or take minutes to build a string nobody will read.
    #
    # The rules:
    #
    # * Never raise. On total failure return {UNINSPECTABLE}.
    # * Never trust a method defined on the object. Class lookup, and iteration over the built-in
    #   collections, go through unbound methods taken from the real core classes.
    # * Build the string incrementally for `Array`, `Hash` and `String`, stopping as soon as the
    #   limit is reached. A one-million element array must not be inspected in full and then
    #   trimmed, it must never be inspected in full at all.
    #
    # `Array` and `Hash` are formatted here rather than by their own `#inspect`, so the output is
    # stable across Ruby versions and independent of any override: `["a", 1]`, `{"a" => 1}`.
    #
    # @api private
    # @since 3.1.0
    module Inspector
      # Default maximum length, in characters, of a returned string.
      #
      # @api private
      # @since 3.1.0
      DEFAULT_LIMIT = 2_000

      # Trailing marker for a truncated string. Deliberately a single character, so a truncated
      # string is exactly `limit` characters long.
      #
      # @api private
      # @since 3.1.0
      ELLIPSIS = "…"

      # Returned when nothing at all could be learned about the object.
      #
      # @api private
      # @since 3.1.0
      UNINSPECTABLE = "#<uninspectable>"

      # Returned by {.class_name} when the object has no reachable class, e.g. a `BasicObject`
      # subclass.
      #
      # @api private
      # @since 3.1.0
      UNKNOWN_CLASS = "#<unknown>"

      # How deep to descend into nested collections before giving up. Bounds both the output size
      # and the recursion, so a deeply nested structure cannot exhaust the stack.
      #
      # @api private
      # @since 3.1.0
      MAX_DEPTH = 6

      # Marker for a collection that contains itself, mirroring Ruby's own output.
      #
      # @api private
      # @since 3.1.0
      RECURSIVE_ARRAY = "[...]"

      # @api private
      # @since 3.1.0
      RECURSIVE_HASH = "{...}"

      # Unbound methods from the real core classes. Binding these is the only way to be sure we
      # are running the implementation we think we are: the object may have redefined `#class`,
      # `#each`, `#object_id` or anything else, and on the error page a lie is more likely than
      # anywhere else in the stack.
      #
      # `#class` and `#object_id` are owned by `Kernel`, a module, so they bind to a `BasicObject`
      # too: an object that cannot answer `#class` itself can still be named here.
      #
      # @api private
      # @since 3.1.0
      OBJECT_CLASS = ::Object.instance_method(:class)

      # @api private
      # @since 3.1.0
      OBJECT_ID = ::Object.instance_method(:object_id)

      # @api private
      # @since 3.1.0
      MODULE_NAME = ::Module.instance_method(:name)

      # @api private
      # @since 3.1.0
      MODULE_TO_S = ::Module.instance_method(:to_s)

      # @api private
      # @since 3.1.0
      MODULE_SUBSET = ::Module.instance_method(:<=)

      # @api private
      # @since 3.1.0
      ARRAY_EACH = ::Array.instance_method(:each)

      # @api private
      # @since 3.1.0
      HASH_EACH_PAIR = ::Hash.instance_method(:each_pair)

      # @api private
      # @since 3.1.0
      STRING_BYTESLICE = ::String.instance_method(:byteslice)

      # @api private
      # @since 3.1.0
      STRING_INSPECT = ::String.instance_method(:inspect)

      class << self
        # Returns a printable representation of `object`, at most `limit` characters long.
        #
        # @param object [Object] anything at all, including `BasicObject`
        # @param limit [Integer] maximum length of the returned string, in characters
        #
        # @return [String] always a valid UTF-8 String, never longer than `limit`
        #
        # @api private
        # @since 3.1.0
        def call(object, limit: DEFAULT_LIMIT)
          limit = normalize_limit(limit)

          truncate(sanitize(build(object, limit, 0, [])), limit)
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNINSPECTABLE
        end

        # Returns the name of the object's real class, ignoring any `#class` the object defines.
        #
        # @param object [Object]
        #
        # @return [String] the class name, or {UNKNOWN_CLASS} when there is none
        #
        # @api private
        # @since 3.1.0
        def class_name(object)
          klass = real_class(object)
          return UNKNOWN_CLASS unless klass

          name = MODULE_NAME.bind_call(klass) || MODULE_TO_S.bind_call(klass)
          name = sanitize(name.to_s)

          name.empty? ? UNKNOWN_CLASS : name
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNKNOWN_CLASS
        end

        private

        # @api private
        # @since 3.1.0
        def build(object, limit, depth, seen)
          klass = real_class(object)

          if klass.nil?
            plain_inspect(object, limit)
          elsif subclass_of?(klass, ::String)
            string_inspect(object, limit)
          elsif subclass_of?(klass, ::Array)
            array_inspect(object, limit, depth, seen)
          elsif subclass_of?(klass, ::Hash)
            hash_inspect(object, limit, depth, seen)
          else
            plain_inspect(object, limit)
          end
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNINSPECTABLE
        end

        # Calls the object's own `#inspect`, then verifies what came back.
        #
        # This is the one place we cannot bound the work: an arbitrary `#inspect` may build a
        # gigantic string, or never return. Nothing short of a separate thread can fix that, and a
        # thread would be worse. We take what we are given and cut it down immediately.
        #
        # @api private
        # @since 3.1.0
        def plain_inspect(object, limit)
          result = object.inspect
          klass = real_class(result)

          unless klass && subclass_of?(klass, ::String)
            return describe(object, "#inspect returned #{class_name(result)}")
          end

          string_inspect_result(result, limit)
        rescue ::Exception => exception # rubocop:disable Lint/RescueException
          describe(object, "#inspect raised #{class_name(exception)}")
        end

        # Inspects a String without materialising more of it than the limit can show.
        #
        # Slices bytes rather than characters: the string may have an invalid encoding, and
        # character indexing raises on those.
        #
        # @api private
        # @since 3.1.0
        def string_inspect(object, limit)
          # Four bytes per character is the worst case for UTF-8, so this cannot cut short a
          # string that would otherwise have fitted.
          slice = STRING_BYTESLICE.bind_call(object, 0, (limit + 1) * 4)

          string_inspect_result(STRING_INSPECT.bind_call(sanitize(slice)), limit)
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNINSPECTABLE
        end

        # @api private
        # @since 3.1.0
        def string_inspect_result(result, limit)
          truncate(sanitize(result), limit)
        end

        # @api private
        # @since 3.1.0
        def array_inspect(object, limit, depth, seen)
          id = safe_object_id(object)
          marker = collection_marker(id, seen, depth, RECURSIVE_ARRAY, "[#{ELLIPSIS}]")
          return marker if marker

          nested = nest(seen, id)
          state = {out: +"[", first: true, truncated: false}

          ARRAY_EACH.bind_call(object) do |element|
            break unless open_entry(state, limit)

            state[:out] << build(element, remaining(limit, state[:out]), depth + 1, nested)
          end

          close_entries(state, "]")
        end

        # @api private
        # @since 3.1.0
        def hash_inspect(object, limit, depth, seen)
          id = safe_object_id(object)
          marker = collection_marker(id, seen, depth, RECURSIVE_HASH, "{#{ELLIPSIS}}")
          return marker if marker

          nested = nest(seen, id)
          state = {out: +"{", first: true, truncated: false}

          HASH_EACH_PAIR.bind_call(object) do |key, value|
            break unless open_entry(state, limit)

            out = state[:out]
            out << build(key, remaining(limit, out), depth + 1, nested)
            out << " => "
            out << build(value, remaining(limit, out), depth + 1, nested)
          end

          close_entries(state, "}")
        end

        # Returns the replacement for a collection we must not descend into, or nil to carry on.
        #
        # @api private
        # @since 3.1.0
        def collection_marker(id, seen, depth, cycle, too_deep)
          return cycle if id && seen.include?(id)
          return too_deep if depth >= MAX_DEPTH

          nil
        end

        # @api private
        # @since 3.1.0
        def nest(seen, id)
          id ? seen + [id] : seen
        end

        # Opens the next entry, or reports that the limit is reached and iteration must stop.
        #
        # @api private
        # @since 3.1.0
        def open_entry(state, limit)
          if state[:out].length >= limit
            state[:truncated] = true
            return false
          end

          state[:out] << ", " unless state[:first]
          state[:first] = false
          true
        end

        # @api private
        # @since 3.1.0
        def close_entries(state, closing)
          state[:out] << (state[:first] ? ELLIPSIS : ", #{ELLIPSIS}") if state[:truncated]
          state[:out] << closing
        end

        # Returns `"#<Foo (reason)>"`, or {UNINSPECTABLE} when even the class is unknown.
        #
        # @api private
        # @since 3.1.0
        def describe(object, reason)
          name = class_name(object)
          return UNINSPECTABLE if name == UNKNOWN_CLASS

          "#<#{name} (#{reason})>"
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNINSPECTABLE
        end

        # @api private
        # @since 3.1.0
        def real_class(object)
          OBJECT_CLASS.bind_call(object)
        rescue ::Exception # rubocop:disable Lint/RescueException
          nil
        end

        # @api private
        # @since 3.1.0
        def subclass_of?(klass, ancestor)
          MODULE_SUBSET.bind_call(klass, ancestor) ? true : false
        rescue ::Exception # rubocop:disable Lint/RescueException
          false
        end

        # @api private
        # @since 3.1.0
        def safe_object_id(object)
          OBJECT_ID.bind_call(object)
        rescue ::Exception # rubocop:disable Lint/RescueException
          nil
        end

        # @api private
        # @since 3.1.0
        def remaining(limit, out)
          left = limit - out.length
          left < 1 ? 1 : left
        end

        # @api private
        # @since 3.1.0
        def normalize_limit(limit)
          limit = ::Kernel.Integer(limit)
          limit < 1 ? 1 : limit
        rescue ::Exception # rubocop:disable Lint/RescueException
          DEFAULT_LIMIT
        end

        # @api private
        # @since 3.1.0
        def truncate(string, limit)
          return string if string.length <= limit

          "#{string[0, limit - 1]}#{ELLIPSIS}"
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNINSPECTABLE
        end

        # Guarantees valid UTF-8. The result goes straight into an HTML document, and a stray
        # invalid byte sequence blows up much later, in the template, where it is unrecoverable.
        #
        # @api private
        # @since 3.1.0
        def sanitize(string)
          string = string.encode(::Encoding::UTF_8, invalid: :replace, undef: :replace) unless
            string.encoding == ::Encoding::UTF_8

          string.valid_encoding? ? string : string.scrub("?")
        rescue ::Exception # rubocop:disable Lint/RescueException
          UNINSPECTABLE
        end
      end
    end
  end
end
