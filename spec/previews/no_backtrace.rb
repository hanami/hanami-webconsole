# frozen_string_literal: true

# An exception that was built but never raised, so it has no backtrace.
Previews.scenario "no_backtrace", "Exception with no backtrace" do
  ArgumentError.new("wrong number of arguments (given 1, expected 0)")
end
