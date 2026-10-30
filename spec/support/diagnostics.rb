# frozen_string_literal: true

RSpec.configure do |config|
  # The diagnostics registry is global. Specs tagged `:isolate_diagnostics` can register diagnostics
  # freely: the registry is restored after each example, including the diagnostics the gem ships.
  config.around(:each, :isolate_diagnostics) do |example|
    registry = Hanami::Diagnostics::Registry
    saved = registry.entries.dup

    begin
      example.run
    ensure
      registry.entries.replace(saved)
      # Names warn only once per process, so forget them, for specs that expect a warning.
      registry.instance_variable_get(:@warned_entries).clear
    end
  end
end
