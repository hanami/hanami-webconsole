# frozen_string_literal: true

# The presenter registry is global state, and specs both register into it and reset it. Snapshot
# it around every example so that what one spec does to it cannot reach the next — including the
# registrations the gem itself ships with.
RSpec.configure do |config|
  config.around do |example|
    registry = Hanami::Webconsole::Presenters
    registered = registry.registered

    example.run

    registry.reset!
    registered.each { |name, klass| registry.register(name, klass) }
  end
end
