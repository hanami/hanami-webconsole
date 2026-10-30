# frozen_string_literal: true

RSpec.describe Hanami::Webconsole::Safety do
  subject(:safe) do
    Class.new {
      include Hanami::Webconsole::Safety

      def call(fallback, &block) = safely(fallback, &block)
    }.new
  end

  it "returns the block's value" do
    expect(safe.call(:fallback) { :value }).to eq(:value)
  end

  [StandardError, NotImplementedError, SystemStackError].each do |error_class|
    it "returns the fallback when the block raises #{error_class}" do
      expect(safe.call(:fallback) { raise error_class }).to eq(:fallback)
    end
  end

  it "doesn't rescue errors that must stop the request" do
    expect { safe.call(:fallback) { raise NoMemoryError } }.to raise_error(NoMemoryError)
    expect { safe.call(:fallback) { raise Interrupt } }.to raise_error(Interrupt)
  end
end
