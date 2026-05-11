# frozen_string_literal: true

require "rails_helper"

RSpec.describe CommandPolicy do
  let(:linux_device)   { instance_double("Device", platform_name: "linux") }
  let(:windows_device) { instance_double("Device", platform_name: "windows") }
  let(:macos_device)   { instance_double("Device", platform_name: "macos") }

  describe ".evaluate -- SAFETY-01 allow-list on Linux" do
    %w[ls cat grep ps df du head tail wc find stat file which env pwd whoami id uname uptime free top].each do |bin|
      it "allows #{bin}" do
        v = described_class.evaluate(binary: bin, args: [], cwd: "/", device: linux_device)
        expect(v.decision).to eq(:allow)
        expect(v.reason).to eq(:allowlisted)
        expect(v.resolved_binary).to eq("/usr/bin/#{bin}")
      end
    end
  end

  describe ".evaluate -- SAFETY-02 deny-list on Linux (needs_confirm not unknown_binary)" do
    %w[rm mv dd mkfs mount shutdown reboot kill sudo su chmod chown passwd useradd usermod].each do |bin|
      it "needs_confirm for #{bin}" do
        v = described_class.evaluate(binary: bin, args: [], cwd: "/", device: linux_device)
        expect(v.decision).to eq(:needs_confirm)
        expect(v.reason).to eq(:deny_list)
        expect(v.resolved_binary).to eq("/usr/bin/#{bin}")
      end
    end
  end

  describe ".evaluate -- SAFETY-05 metacharacter rejection" do
    [";", "|", "&", "$(", "`", ">", "<", "&&", "||"].each do |meta|
      it "rejects metacharacter #{meta.inspect} in args" do
        v = described_class.evaluate(binary: "ls", args: ["foo#{meta}bar"], cwd: "/", device: linux_device)
        expect(v.decision).to eq(:deny)
        expect(v.reason).to eq(:metacharacter)
      end

      it "rejects metacharacter #{meta.inspect} in binary name" do
        v = described_class.evaluate(binary: "ls#{meta}", args: [], cwd: "/", device: linux_device)
        expect(v.decision).to eq(:deny)
        expect(v.reason).to eq(:metacharacter)
      end
    end

    it "metacharacter rejection runs BEFORE allow-list (order matters)" do
      v = described_class.evaluate(binary: "ls", args: ["foo;rm -rf /"], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:metacharacter)
    end
  end

  describe ".evaluate -- SAFETY-06 path-shadow / absolute-path resolution" do
    it "rejects relative path with slash (e.g. ./malicious)" do
      v = described_class.evaluate(binary: "./bad", args: [], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:path_shadow)
    end

    it "rejects PATH-shadowed name (e.g. /tmp/ls)" do
      v = described_class.evaluate(binary: "/tmp/ls", args: [], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:path_shadow)
    end

    it "accepts the canonical absolute path verbatim" do
      v = described_class.evaluate(binary: "/usr/bin/ls", args: [], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:allow)
      expect(v.reason).to eq(:allowlisted)
      expect(v.resolved_binary).to eq("/usr/bin/ls")
    end
  end

  describe ".evaluate -- D-04 unknown-binary refusal" do
    it "rejects a Windows-only binary on Linux device" do
      v = described_class.evaluate(binary: "tasklist", args: [], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:unknown_binary)
    end

    it "rejects a binary on an unknown platform (e.g. macos)" do
      v = described_class.evaluate(binary: "ls", args: [], cwd: "/", device: macos_device)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:unknown_binary)
    end
  end

  describe ".evaluate -- per-platform asymmetry on Windows (SAFETY-03 outside-list / default-deny middle zone)" do
    %w[where tasklist findstr hostname whoami systeminfo].each do |bin|
      it "needs_confirm for #{bin} on windows (outside Linux ALLOW_LIST)" do
        v = described_class.evaluate(binary: bin, args: [], cwd: 'C:\\', device: windows_device)
        # Windows binaries are in BINARY_PATHS["windows"] but NOT in the (Linux-shaped)
        # ALLOW_LIST. They fall through to :outside_list per SAFETY-03.
        expect(v.decision).to eq(:needs_confirm)
        expect(v.reason).to eq(:outside_list)
        expect(v.resolved_binary).to start_with('C:\\Windows\\System32\\')
      end
    end
  end

  describe ".warn_missing_paths!" do
    it "does not raise even when paths are missing" do
      expect { described_class.warn_missing_paths! }.not_to raise_error
    end
  end
end
