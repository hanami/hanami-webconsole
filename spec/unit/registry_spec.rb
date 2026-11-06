# frozen_string_literal: true

require "hanami/webconsole/registry"

RSpec.describe Hanami::Webconsole::Registry do
  subject(:registry) { described_class.new }

  # A plain object rather than a double: these are handed between threads below, and only #id is
  # ever asked for.
  let(:page_class) { Struct.new(:id) }

  def page(id)
    page_class.new(id)
  end

  describe "#put" do
    it "returns the page id" do
      expect(registry.put(page("1-a"))).to eq("1-a")
    end

    it "stores the page" do
      stored = page("1-a")
      registry.put(stored)

      expect(registry.fetch("1-a")).to be(stored)
    end

    it "keeps several pages live at once" do
      first = page("1-a")
      second = page("1-b")

      registry.put(first)
      registry.put(second)

      expect(registry.fetch("1-a")).to be(first)
      expect(registry.fetch("1-b")).to be(second)
    end

    it "evicts the least recently used page beyond the bound" do
      registry = described_class.new(max: 2)

      registry.put(page("1-a"))
      registry.put(page("1-b"))
      registry.put(page("1-c"))

      expect(registry.fetch("1-a")).to be_nil
      expect(registry.fetch("1-b")).not_to be_nil
      expect(registry.fetch("1-c")).not_to be_nil
    end

    it "counts a fetch as a use" do
      registry = described_class.new(max: 2)

      registry.put(page("1-a"))
      registry.put(page("1-b"))
      registry.fetch("1-a")
      registry.put(page("1-c"))

      expect(registry.fetch("1-a")).not_to be_nil
      expect(registry.fetch("1-b")).to be_nil
    end

    it "replaces a page stored under the same id" do
      registry.put(page("1-a"))
      replacement = page("1-a")
      registry.put(replacement)

      expect(registry.fetch("1-a")).to be(replacement)
      expect(registry.size).to eq(1)
    end
  end

  describe "#fetch" do
    it "returns nil for an unknown id" do
      expect(registry.fetch("nope")).to be_nil
      expect(registry.fetch(nil)).to be_nil
    end
  end

  describe "thread safety" do
    it "survives concurrent puts and fetches" do
      registry = described_class.new(max: 8)
      pages = 8.times.map { |i| Array.new(20) { |n| page("#{i}-#{n}") } }

      threads = pages.map { |thread_pages|
        Thread.new do
          thread_pages.each do |stored|
            registry.put(stored)
            registry.fetch(stored.id)
          end
        end
      }

      expect { threads.each(&:join) }.not_to raise_error
      expect(registry.size).to be <= 8
    end
  end
end
