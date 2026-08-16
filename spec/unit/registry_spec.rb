# frozen_string_literal: true

require "hanami/webconsole/registry"

RSpec.describe Hanami::Webconsole::Registry do
  subject(:registry) { described_class.new }

  # The generation is process-global, so restore it rather than leaking a bump into other specs.
  around do |example|
    original = Hanami::Webconsole.instance_variable_get(:@generation)
    example.run
    Hanami::Webconsole.instance_variable_set(:@generation, original)
  end

  # A plain object rather than a double: these are handed between threads below, and only #id and
  # #generation are ever asked for.
  let(:page_class) { Struct.new(:id, :generation) }

  def page(id, generation = Hanami::Webconsole.generation)
    page_class.new(id, generation)
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

    it "returns nil after a reload, for a page from the previous generation" do
      stored = page("#{Hanami::Webconsole.generation}-a")
      registry.put(stored)

      expect(registry.fetch(stored.id)).to be(stored)

      Hanami::Webconsole.reloaded!

      expect(registry.fetch(stored.id)).to be_nil
    end

    it "drops the stale page rather than holding its bindings" do
      stored = page("1-a")
      registry.put(stored)

      Hanami::Webconsole.reloaded!
      registry.fetch("1-a")

      expect(registry.size).to eq(0)
    end

    it "still returns pages created after the reload" do
      registry.put(page("1-a"))

      Hanami::Webconsole.reloaded!

      fresh = page("2-b")
      registry.put(fresh)

      expect(registry.fetch("2-b")).to be(fresh)
      expect(registry.fetch("1-a")).to be_nil
    end
  end

  describe "#sweep!" do
    it "drops pages from previous generations" do
      registry.put(page("1-a"))
      registry.put(page("1-b"))

      Hanami::Webconsole.reloaded!
      registry.put(page("2-c"))

      registry.sweep!

      expect(registry.size).to eq(1)
      expect(registry.fetch("2-c")).not_to be_nil
    end

    it "returns itself" do
      expect(registry.sweep!).to be(registry)
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
