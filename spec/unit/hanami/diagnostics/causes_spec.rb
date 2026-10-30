# frozen_string_literal: true

RSpec.describe Hanami::Diagnostics::Causes, ".of" do
  def causes_of(exception)
    described_class.of(exception)
  end

  def with_cause(exception, cause)
    exception.define_singleton_method(:cause) { cause }
    exception
  end

  it "returns the causes, from outermost to innermost" do
    inner = ArgumentError.new("inner")
    middle = with_cause(KeyError.new("middle"), inner)
    outer = with_cause(RuntimeError.new("outer"), middle)

    expect(causes_of(outer)).to eq([middle, inner])
  end

  it "stops at a cause that isn't an exception" do
    expect(causes_of(with_cause(RuntimeError.new, "not an exception"))).to eq([])
  end

  it "stops at a cause that is the exception itself" do
    exception = RuntimeError.new
    with_cause(exception, exception)

    expect(causes_of(exception)).to eq([])
  end

  it "stops at a loop that doesn't include the exception itself" do
    first = KeyError.new("first")
    second = with_cause(ArgumentError.new("second"), first)
    with_cause(first, second)
    outer = with_cause(RuntimeError.new("outer"), first)

    expect(causes_of(outer)).to eq([first, second])
  end

  it "stops after the maximum number of causes" do
    chain = Array.new(described_class::MAX + 5) { RuntimeError.new }
    chain.each_cons(2) { |exception, cause| with_cause(exception, cause) }

    expect(causes_of(chain.first).length).to eq(described_class::MAX)
  end

  it "returns the causes found so far if a cause can't be read" do
    broken = RuntimeError.new("broken")
    broken.define_singleton_method(:cause) { raise "no cause for you" }
    outer = with_cause(RuntimeError.new("outer"), broken)

    expect(causes_of(outer)).to eq([broken])
  end
end
