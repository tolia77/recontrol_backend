# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolResultSanitiser do
  describe ".call recursive walk" do
    it "sanitises string values but keeps numeric values untouched" do
      input = { stdout: "ok\e[0m", exit_code: 0, elapsed_seconds: 0.123 }

      output = described_class.call(input)

      expect(output).to eq({ stdout: "ok", exit_code: 0, elapsed_seconds: 0.123 })
    end

    it "does not sanitise hash keys" do
      input = { "stdout\e[0m" => "ok\e[0m" }

      output = described_class.call(input)

      expect(output.keys).to eq(["stdout\e[0m"])
      expect(output["stdout\e[0m"]).to eq("ok")
    end

    it "does not mutate the input object" do
      input = { stdout: "ok\e[0m" }

      described_class.call(input)

      expect(input[:stdout]).to eq("ok\e[0m")
    end

    it "sanitises arrays element-wise" do
      expect(described_class.call(["a\e[0m", "b"])).to eq(["a", "b"])
    end

    it "passes through integer float boolean and nil untouched" do
      expect(described_class.call(42)).to eq(42)
      expect(described_class.call(1.5)).to eq(1.5)
      expect(described_class.call(true)).to be(true)
      expect(described_class.call(false)).to be(false)
      expect(described_class.call(nil)).to be_nil
    end

    it "handles deep nesting for hash/array/string values" do
      input = { stdout: { lines: ["\e[31ma\e[0m", "b\t\nc"], meta: { exit: 0 } } }

      expect(described_class.call(input)).to eq(
        { stdout: { lines: ["a", "b\t\nc"], meta: { exit: 0 } } }
      )
    end
  end

  describe ".sanitise_string ANSI + ctrl strip" do
    it "strips ls --color line" do
      expect(described_class.send(:sanitise_string, "\e[01;34mdir\e[0m\n")).to eq("dir\n")
    end

    it "strips top redraw" do
      expect(described_class.send(:sanitise_string, "\e[H\e[2J\e[1;32mfoo\e[0m")).to eq("foo")
    end

    it "strips OSC title" do
      expect(described_class.send(:sanitise_string, "\e]0;tab title\afoo")).to eq("foo")
    end

    it "strips OSC8 hyperlink" do
      expect(described_class.send(:sanitise_string, "\e]8;;https://x.com\e\\link\e]8;;\e\\\n")).to eq("link\n")
    end

    it "strips cursor save and restore" do
      expect(described_class.send(:sanitise_string, "\e7before\e8after")).to eq("beforeafter")
    end

    it "preserves newline and tab while stripping control chars" do
      expect(described_class.send(:sanitise_string, "a\nb\tc\x00d\x07e\x1Ff")).to eq("a\nb\tcdef")
    end

    it "keeps empty string unchanged" do
      expect(described_class.send(:sanitise_string, "")).to eq("")
    end

    it "keeps plain text unchanged" do
      expect(described_class.send(:sanitise_string, "plain text\n")).to eq("plain text\n")
    end
  end

  describe ".sanitise_string mb_chars truncation" do
    it "Cyrillic 2-byte codepoints align exactly at 4096 bytes" do
      input = "я" * 2050
      output = described_class.send(:sanitise_string, input)

      expect(output.bytesize).to eq(4096)
      expect(output.length).to eq(2048)
      expect(output.valid_encoding?).to be(true)
    end

    it "CJK 3-byte codepoints stop at 4095 bytes (1 byte short)" do
      input = "中" * 1400
      output = described_class.send(:sanitise_string, input)

      expect(output.bytesize).to eq(4095)
      expect(output.length).to eq(1365)
      expect(output.valid_encoding?).to be(true)
    end

    it "emoji 4-byte codepoints align exactly at 4096 bytes" do
      input = "😀" * 1100
      output = described_class.send(:sanitise_string, input)

      expect(output.bytesize).to eq(4096)
      expect(output.length).to eq(1024)
      expect(output.valid_encoding?).to be(true)
    end

    it "leaves short strings unchanged" do
      expect(described_class.send(:sanitise_string, "hello world")).to eq("hello world")
    end
  end

  describe ".redact_secrets" do
    it "redacts AWS env-var" do
      input = "AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE"
      expect(described_class.redact_secrets(input)).to eq("AWS_SECRET_ACCESS_KEY=[REDACTED]")
    end

    it "redacts bare AWS key" do
      input = "key id is AKIAIOSFODNN7EXAMPLE here"
      expect(described_class.redact_secrets(input)).to eq("key id is [REDACTED] here")
    end

    it "redacts PEM private key block" do
      input = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEvQIB...AoIBAQC7VJTUt9Us8cKB\n-----END RSA PRIVATE KEY-----\nafter"
      expect(described_class.redact_secrets(input)).to eq("before\n[REDACTED]\nafter")
    end

    it "redacts PostgreSQL URI" do
      input = "Connecting to postgres://admin:hunter2@10.0.0.5/prod and listening"
      expect(described_class.redact_secrets(input)).to eq("Connecting to [REDACTED] and listening")
    end

    it "redacts MongoDB URI" do
      input = "Connecting to mongodb+srv://u:p@cluster0.example.net/db ok"
      expect(described_class.redact_secrets(input)).to eq("Connecting to [REDACTED] ok")
    end

    it "redacts env-var token value" do
      input = "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
      expect(described_class.redact_secrets(input)).to eq("GITHUB_TOKEN=[REDACTED]")
    end

    it "redacts quoted env-var value" do
      input = "API_PASSWORD=\"my secret\""
      expect(described_class.redact_secrets(input)).to eq("API_PASSWORD=[REDACTED]")
    end

    it "redacts single-quoted env-var value" do
      input = "MY_KEY='single-quoted-value-here'"
      expect(described_class.redact_secrets(input)).to eq("MY_KEY=[REDACTED]")
    end

    it "redacts generic base64 of 40+ characters" do
      input = "leftover blob: dGhpcyBpcyBhIHRlc3Qgc3RyaW5nIHRoYXQgaXMgZXhhY3RseSBmb3J0eSBjaGFycw=="
      expect(described_class.redact_secrets(input)).to eq("leftover blob: [REDACTED]")
    end

    it "does not redact short base64" do
      input = "hash: dGVzdA=="
      expect(described_class.redact_secrets(input)).to eq("hash: dGVzdA==")
    end

    it "passes through text without secrets" do
      input = "stdout: hello world\nfile1.txt\nfile2.txt"
      expect(described_class.redact_secrets(input)).to eq("stdout: hello world\nfile1.txt\nfile2.txt")
    end
  end

  describe "constants" do
    it "locks truncate bytes to 4096" do
      expect(described_class::TRUNCATE_BYTES).to eq(4_096)
    end

    it "keeps secret patterns frozen as array pairs" do
      expect(described_class::SECRET_PATTERNS).to be_frozen
      expect(described_class::SECRET_PATTERNS).to all(be_a(Array))
    end
  end
end
