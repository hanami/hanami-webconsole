# frozen_string_literal: true

# An error wrapping two causes.
module Bookshelf
  class SyncError < StandardError; end
  class TimeoutError < StandardError; end

  class Sync
    def call
      fetch
    rescue TimeoutError
      raise SyncError, "Couldn't sync the catalogue"
    end

    def fetch
      connect
    rescue Errno::ECONNREFUSED
      raise TimeoutError, "Gave up after 3 attempts"
    end

    def connect
      raise Errno::ECONNREFUSED, "connect(2) for 10.0.0.5:443"
    end
  end
end

Previews.scenario "cause_chain", "Error with two nested causes" do
  Bookshelf::Sync.new.call
end
