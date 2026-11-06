# frozen_string_literal: true

module Hanami
  module Diagnostics
    # Context for a diagnostic, given to it alongside the exception when it is built.
    #
    # Gives the diagnostic access to the running app via a slice.
    #
    # Every diagnostic receives this, so it's part of the diagnostic contract (see
    # {Hanami::Diagnostics.register}).
    #
    # **Experimental:** this API may change in a later release.
    #
    # @!attribute [r] slice
    #   @return [Hanami::Slice, nil] the slice that the webconsole middleware belongs to. Since
    #     slice routes are loaded into the app's router, this will nearly always be the app itself.
    #
    # @api public
    # @since 3.1.0
    Context = Data.define(:slice)
  end
end
