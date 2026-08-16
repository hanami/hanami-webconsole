# frozen_string_literal: true

require "hanami/webconsole/filters"

RSpec.describe Hanami::Webconsole::Filters do
  subject(:filters) { described_class.new(keys) }

  let(:keys) { ["password", "token"] }

  describe "#filtered?" do
    it "matches an exact key" do
      expect(filters.filtered?("password")).to be(true)
    end

    it "matches case-insensitively" do
      expect(filters.filtered?("PASSWORD")).to be(true)
      expect(filters.filtered?("Password")).to be(true)
      expect(filters.filtered?("PaSsWoRd")).to be(true)
    end

    it "matches a substring of the key, as the logger filter does" do
      expect(filters.filtered?("user_password")).to be(true)
      expect(filters.filtered?("password_confirmation")).to be(true)
      expect(filters.filtered?("csrf_token_value")).to be(true)
    end

    it "does not match unrelated keys" do
      expect(filters.filtered?("email")).to be(false)
      expect(filters.filtered?("passwor")).to be(false)
      expect(filters.filtered?("")).to be(false)
      expect(filters.filtered?(nil)).to be(false)
    end

    it "accepts symbol keys" do
      expect(filters.filtered?(:password)).to be(true)
      expect(filters.filtered?(:email)).to be(false)
    end

    it "is case-insensitive about the configured keys too" do
      expect(described_class.new(["PASSWORD"]).filtered?("user_password")).to be(true)
    end

    context "with no keys" do
      let(:keys) { [] }

      it "matches nothing" do
        expect(filters.filtered?("password")).to be(false)
      end
    end
  end

  describe "#keys" do
    let(:keys) { ["Password", :token, "", nil, "password"] }

    it "normalises the configured keys" do
      expect(filters.keys).to eq(["password", "token"])
    end

    it "ignores a non-array" do
      expect(described_class.new(nil).keys).to eq([])
      expect(described_class.new("password").keys).to eq([])
    end

    it "defaults to no keys" do
      expect(described_class.new.keys).to eq([])
    end
  end

  describe "#call" do
    it "replaces matching values with the marker" do
      result = filters.call({"email" => "a@b.com", "password" => "secret"})

      expect(result).to eq({"email" => "a@b.com", "password" => "[FILTERED]"})
    end

    it "uses the FILTERED constant, so callers can tell it from a literal value" do
      result = filters.call({"password" => "secret", "note" => "[FILTERED]"})

      expect(result["password"]).to be(described_class::FILTERED)
      expect(result["note"]).not_to be(described_class::FILTERED)
    end

    it "does not modify the original hash" do
      original = {"password" => "secret"}
      filters.call(original)

      expect(original).to eq({"password" => "secret"})
    end

    it "preserves key objects" do
      expect(filters.call({password: "secret", email: "a@b"}))
        .to eq({password: "[FILTERED]", email: "a@b"})
    end

    it "redacts whatever the value is" do
      expect(filters.call({"password" => {"nested" => 1}})).to eq({"password" => "[FILTERED]"})
      expect(filters.call({"password" => [1, 2]})).to eq({"password" => "[FILTERED]"})
      expect(filters.call({"password" => nil})).to eq({"password" => "[FILTERED]"})
    end

    it "filters nested hashes" do
      result = filters.call(
        {"user" => {"email" => "a@b.com", "password" => "secret", "profile" => {"token" => "t"}}}
      )

      expect(result).to eq(
        {"user" => {"email" => "a@b.com", "password" => "[FILTERED]",
                    "profile" => {"token" => "[FILTERED]"}}}
      )
    end

    it "filters hashes nested in arrays" do
      result = filters.call({"users" => [{"password" => "a"}, {"email" => "b"}]})

      expect(result).to eq({"users" => [{"password" => "[FILTERED]"}, {"email" => "b"}]})
    end

    it "filters hashes nested in arrays of arrays" do
      result = filters.call({"rows" => [[{"token" => "t"}]]})

      expect(result).to eq({"rows" => [[{"token" => "[FILTERED]"}]]})
    end

    it "leaves non-hash values alone" do
      result = filters.call({"n" => 1, "list" => [1, "two", nil], "obj" => :sym})

      expect(result).to eq({"n" => 1, "list" => [1, "two", nil], "obj" => :sym})
    end

    it "returns an empty hash for anything that is not a hash" do
      expect(filters.call(nil)).to eq({})
      expect(filters.call("password=secret")).to eq({})
      expect(filters.call([{"password" => "x"}])).to eq({})
    end

    it "does not recurse forever on a self-referential hash" do
      hash = {"a" => 1}
      hash["self"] = hash

      expect { filters.call(hash) }.not_to raise_error
    end

    it "does not recurse forever on a self-referential array" do
      array = []
      array << array

      expect { filters.call({"list" => array}) }.not_to raise_error
    end

    it "filters a hash subclass" do
      klass = Class.new(Hash)
      hash = klass.new
      hash["password"] = "secret"

      expect(filters.call(hash)).to eq({"password" => "[FILTERED]"})
    end

    it "is not fooled by an object claiming to be a Hash" do
      liar = Class.new do
        def is_a?(*)
          true
        end

        def kind_of?(*)
          true
        end
      end.new

      expect(filters.call({"a" => liar})["a"]).to be(liar)
    end

    it "redacts a value whose key raises while being matched, rather than leaking it" do
      key = Class.new do
        def to_s
          raise "no"
        end
      end.new

      expect(filters.call({key => "secret"}).values).to eq(["[FILTERED]"])
    end

    it "redacts a value whose key cannot be stringified at all" do
      key = Class.new(BasicObject) do
        def hash
          1
        end

        def eql?(*)
          false
        end
      end.new

      expect(filters.call({key => "secret"}).values).to eq(["[FILTERED]"])
    end

    context "with no keys" do
      let(:keys) { [] }

      it "passes everything through" do
        expect(filters.call({"password" => "secret"})).to eq({"password" => "secret"})
      end
    end
  end
end
