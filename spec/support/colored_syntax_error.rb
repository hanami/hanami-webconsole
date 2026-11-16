# frozen_string_literal: true

require "pty"

# Helpers to get real syntax errors with the ANSI colour codes Ruby adds when stderr is a terminal.
#
# On Ruby 3.4+, Prism colours the source excerpt in a syntax error's message, but only if stderr
# is a terminal. Moving stderr onto a pseudo-terminal makes Ruby add the codes, even when the specs
# run without a terminal (as on CI).
module ColoredSyntaxError
  # Returns the syntax error Ruby raises for the given source, with its colour codes.
  #
  # This skips the spec on Ruby versions that don't colour syntax errors, and fails it if Ruby adds
  # no codes, since the spec would then pass without testing anything.
  #
  # @param source [String] Ruby source with a syntax error
  #
  # @return [SyntaxError]
  def colored_syntax_error(source)
    skip "Ruby #{RUBY_VERSION} doesn't colour syntax errors" if RUBY_VERSION < "3.4"

    exception = on_terminal do
      eval(source, binding, "app/x.rb", 1) # rubocop:disable Security/Eval
      raise "expected #{source.inspect} to raise a SyntaxError"
    rescue SyntaxError => exception
      exception
    end

    raise "expected Ruby to colour the syntax error" unless exception.message.include?("\e[")

    exception
  end

  # Runs the block with stderr on a pseudo-terminal, and returns its value.
  #
  # Ruby checks the process's own stderr (file descriptor 2), not `$stderr`, which a spec may have
  # swapped out. So this moves `STDERR`.
  #
  # rubocop:disable Style/GlobalStdStream
  def on_terminal
    original = STDERR.dup

    PTY.open do |_master, terminal|
      STDERR.reopen(terminal)
      yield
    ensure
      STDERR.reopen(original)
    end
  ensure
    original&.close
  end
  # rubocop:enable Style/GlobalStdStream
end
