# frozen_string_literal: true

require "tmpdir"
require_relative "../previews"

# The preview gallery renders the error page for a range of real errors, so layout changes can be
# checked against states the design doesn't draw. This spec keeps every scenario rendering.
RSpec.describe Previews, :isolate_diagnostics do
  it "has a scenario for each state the page renders" do
    expect(described_class.scenarios.map(&:name)).to include(
      "no_method_error", "runtime_error", "not_found", "destructive_fix", "cause_chain",
      "no_backtrace", "long_message", "huge_context", "xss"
    )
  end

  described_class.scenarios.each do |scenario|
    describe scenario.name do
      subject(:html) { described_class.render(scenario) }

      it "renders the exception class" do
        expect(html).to start_with("<!DOCTYPE html>")
        expect(html).to include(scenario.page.exception_class)
      end

      it "escapes everything it was given" do
        expect(html).not_to include("<script>alert(1)</script>")
      end
    end
  end

  it "shows the fix for the actionable scenarios" do
    expect(described_class.render(described_class.find("destructive_fix"))).to include("data-destructive")
    expect(described_class.render(described_class.find("not_found"))).to include("data-webconsole-fix")
  end

  it "writes every scenario and an index linking them" do
    Dir.mktmpdir do |dir|
      described_class.write(dir)

      index = File.read(File.join(dir, "index.html"))
      described_class.scenarios.each do |scenario|
        expect(File).to exist(File.join(dir, "#{scenario.name}.html"))
        expect(index).to include(%(href="#{scenario.name}.html"))
      end
    end
  end
end
