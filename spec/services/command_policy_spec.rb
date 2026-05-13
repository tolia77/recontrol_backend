# frozen_string_literal: true

require "rails_helper"

RSpec.describe CommandPolicy do
  let(:linux_device)   { instance_double("Device", platform_name: "linux") }
  let(:windows_device) { instance_double("Device", platform_name: "windows") }
  let(:macos_device)   { instance_double("Device", platform_name: "macos") }

  describe ".evaluate -- platform_name is enforced lowercase canonical" do
    # Canonical form is `linux` / `windows`. Desktop clients send lowercase
    # via `LinuxSystemInfoService.GetPlatformName` / `WindowsSystemInfoService`;
    # the auth controller persists exactly what the client sends. Anything
    # capitalised reaches the unknown_binary gate and is hard-denied — that
    # is intentional: a mis-cased platform name is a bug at the source, not
    # something this layer should paper over.
    it "hard-denies `free` when device.platform_name is `Linux` (capital L)" do
      capital_linux = instance_double("Device", platform_name: "Linux")
      v = described_class.evaluate(binary: "free", args: ["-h"], cwd: "/tmp", device: capital_linux)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:unknown_binary)
    end
  end

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

  describe ".evaluate -- known-but-not-allow-listed binaries on Linux (needs_confirm via outside_list)" do
    # Previously SAFETY-02 split these out as a separate :deny_list zone, but
    # the policy decision was identical to :outside_list. Both collapse here.
    %w[rm mv dd mkfs mount shutdown reboot kill sudo su chmod chown passwd useradd usermod].each do |bin|
      it "needs_confirm via outside_list for #{bin}" do
        v = described_class.evaluate(binary: bin, args: [], cwd: "/", device: linux_device)
        expect(v.decision).to eq(:needs_confirm)
        expect(v.reason).to eq(:outside_list)
        expect(v.resolved_binary).to eq("/usr/bin/#{bin}")
      end
    end
  end

  describe ".evaluate -- unknown binary resolved at runtime (needs_confirm via unverified)" do
    # Before this change, anything not in BINARY_PATHS was hard-denied with
    # :unknown_binary. Now we scan standard system bin dirs and let the
    # operator confirm via Allow/Deny.
    it "resolves /usr/bin/setxkbmap and routes through :unverified when present on the host" do
      skip "setxkbmap not installed on this host" unless File.executable?("/usr/bin/setxkbmap")
      v = described_class.evaluate(binary: "setxkbmap", args: ["-layout", "ua"], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:needs_confirm)
      expect(v.reason).to eq(:unverified)
      expect(v.resolved_binary).to eq("/usr/bin/setxkbmap")
    end

    it "still hard-denies as :unknown_binary when neither pathmap nor runtime scan resolves" do
      v = described_class.evaluate(binary: "totally-not-a-real-binary-xyz", args: [], cwd: "/", device: linux_device)
      expect(v.decision).to eq(:deny)
      expect(v.reason).to eq(:unknown_binary)
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

    context "VERIFY-02 explicit attack-form scenarios" do
      # Per CONTEXT D-10: extend Phase 18/19 specs in place rather than duplicating.
      # Each attack-form below is enumerated in REQUIREMENTS.md VERIFY-02.
      #
      # Argument splitting: AgentRunner surfaces a tool call as {binary:, args:[...]}
      # -- the LLM emits the binary and args separately. The policy must reject ANY
      # metacharacter regardless of which slot it lands in. We feed both halves
      # by splitting on the first whitespace; any metacharacter in either slot
      # must yield decision: :deny / reason: :metacharacter.
      {
        "ls; echo pwned"         => :metacharacter,
        "ls $(echo /tmp)"        => :metacharacter,
        "ls `echo /tmp`"         => :metacharacter,
        "cat /etc/passwd | head" => :metacharacter
      }.each do |attack_form, expected_reason|
        it "VERIFY-02: rejects attack-form #{attack_form.inspect} (#{expected_reason})" do
          parts = attack_form.split(" ", 2)
          binary = parts[0]
          rest   = parts[1].to_s
          args   = rest.empty? ? [] : [rest]

          v = described_class.evaluate(binary: binary, args: args, cwd: "/", device: linux_device)
          expect(v.decision).to eq(:deny)
          expect(v.reason).to eq(expected_reason)
        end
      end
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
