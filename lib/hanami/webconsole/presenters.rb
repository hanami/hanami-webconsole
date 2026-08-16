# frozen_string_literal: true

require_relative "presenters/base"

module Hanami
  module Webconsole
    # Registry mapping exception class names to presenters.
    #
    # Only {Presenters::NotFound} is registered by default; every other error takes the generic
    # page. Presenters are added one at a time, each gated on an exception class specific enough
    # to be worth recognising.
    #
    # Lookup walks the exception's ancestry, so registering a superclass covers its subclasses.
    #
    # @api private
    # @since 3.1.0
    module Presenters
      @registry = {}
      @mutex = Mutex.new

      class << self
        # Registers a presenter for an exception class.
        #
        # The exception class is named as a String so that registration does not force the
        # constant to load, and so that presenters can be registered for exceptions belonging to
        # gems that may not be bundled.
        #
        # @param exception_class_name [String]
        # @param presenter_class [Class]
        #
        # @return [Class] the registered presenter class
        #
        # @api private
        # @since 3.1.0
        def register(exception_class_name, presenter_class)
          @mutex.synchronize do
            @registry[exception_class_name.to_s] = presenter_class
          end

          presenter_class
        end

        # Returns a presenter for the given exception, or nil when none matches.
        #
        # Walks the exception's ancestry, so a subclass of a registered class matches. Never
        # raises: an error page must render even when a presenter misbehaves.
        #
        # @param exception [Exception]
        #
        # @return [Presenters::Base, nil]
        #
        # @api private
        # @since 3.1.0
        def for(exception)
          presenter_class = lookup(exception)
          return nil unless presenter_class

          presenter_class.new(exception)
        rescue StandardError
          nil
        end

        # All registered presenters, keyed by exception class name.
        #
        # @return [Hash{String => Class}]
        #
        # @api private
        # @since 3.1.0
        def registered
          @mutex.synchronize { @registry.dup }
        end

        # Removes every registration.
        #
        # @return [void]
        #
        # @api private
        # @since 3.1.0
        def reset!
          @mutex.synchronize { @registry.clear }
        end

        private

        def lookup(exception)
          ancestors = exception.class.ancestors

          @mutex.synchronize do
            next if @registry.empty?

            ancestors.each do |ancestor|
              name = ancestor.name
              next unless name

              presenter_class = @registry[name]
              return presenter_class if presenter_class
            end
          end

          nil
        end
      end
    end
  end
end
