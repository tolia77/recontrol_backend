# frozen_string_literal: true

# CommandPolicy
# -------------
# D-01..D-04 (Phase 19). Middleware between AiTools::Base#validate and #dispatch.
# Classifies a `run_command` invocation as :allow / :needs_confirm / :deny.
#
# Stateless module_function service. Single entry point:
#   CommandPolicy.evaluate(binary:, args:, cwd:, device:) #=> Verdict
#
# Verdict struct fields:
#   - decision        :: :allow | :needs_confirm | :deny
#   - reason          :: Symbol
#   - resolved_binary :: String absolute path (nil on :deny)
module CommandPolicy
  module_function

  Verdict = Struct.new(:decision, :reason, :resolved_binary, keyword_init: true)

  # SAFETY-01: read-only allow-list. Platform-agnostic; resolved to absolute
  # paths via BINARY_PATHS below. Order is alphabetical for diff-friendliness.
  ALLOW_LIST = %w[
    cat df du env file find free grep head id
    ls ps pwd stat tail top uname uptime wc which whoami
  ].freeze

  # SAFETY-02: explicit deny-list. Members trigger :needs_confirm with
  # reason :deny_list (operator can override). MUST also be present in
  # BINARY_PATHS["linux"] so pathmap lookup resolves first.
  DENY_LIST = %w[
    chmod chown dd kill mkfs mount mv passwd reboot
    rm shutdown su sudo useradd usermod
  ].freeze

  # SAFETY-05: shell metacharacters. ANY occurrence in any args[] string OR
  # in the binary name itself is rejected with reason :metacharacter.
  METACHARACTERS = ["|", "&", ";", "$(", "`", "<", ">", "&&", "||"].freeze

  # SAFETY-06 / D-04: per-platform absolute-path map. Backend rejects with
  # reason :unknown_binary if the requested binary is not in the map for
  # the device's platform. The resolved path replaces args[:binary] before
  # dispatch.
  BINARY_PATHS = {
    "linux" => {
      # SAFETY-01 allow-list (read-only).
      "cat"      => "/usr/bin/cat",
      "df"       => "/usr/bin/df",
      "du"       => "/usr/bin/du",
      "env"      => "/usr/bin/env",
      "file"     => "/usr/bin/file",
      "find"     => "/usr/bin/find",
      "free"     => "/usr/bin/free",
      "grep"     => "/usr/bin/grep",
      "head"     => "/usr/bin/head",
      "id"       => "/usr/bin/id",
      "ls"       => "/usr/bin/ls",
      "ps"       => "/usr/bin/ps",
      "pwd"      => "/usr/bin/pwd",
      "stat"     => "/usr/bin/stat",
      "tail"     => "/usr/bin/tail",
      "top"      => "/usr/bin/top",
      "uname"    => "/usr/bin/uname",
      "uptime"   => "/usr/bin/uptime",
      "wc"       => "/usr/bin/wc",
      "which"    => "/usr/bin/which",
      "whoami"   => "/usr/bin/whoami",
      # SAFETY-02 deny-list (operator-confirmable destructive).
      "chmod"    => "/usr/bin/chmod",
      "chown"    => "/usr/bin/chown",
      "dd"       => "/usr/bin/dd",
      "kill"     => "/usr/bin/kill",
      "mkfs"     => "/usr/bin/mkfs",
      "mount"    => "/usr/bin/mount",
      "mv"       => "/usr/bin/mv",
      "passwd"   => "/usr/bin/passwd",
      "reboot"   => "/usr/bin/reboot",
      "rm"       => "/usr/bin/rm",
      "shutdown" => "/usr/bin/shutdown",
      "su"       => "/usr/bin/su",
      "sudo"     => "/usr/bin/sudo",
      "useradd"  => "/usr/bin/useradd",
      "usermod"  => "/usr/bin/usermod"
    }.freeze,
    "windows" => {
      # Read-only Windows analogues. CMD builtins (type/set/ver) are excluded
      # because they are not standalone executables for direct execve.
      "findstr"    => 'C:\\Windows\\System32\\findstr.exe',
      "hostname"   => 'C:\\Windows\\System32\\hostname.exe',
      "systeminfo" => 'C:\\Windows\\System32\\systeminfo.exe',
      "tasklist"   => 'C:\\Windows\\System32\\tasklist.exe',
      "where"      => 'C:\\Windows\\System32\\where.exe',
      "whoami"     => 'C:\\Windows\\System32\\whoami.exe'
    }.freeze
  }.freeze

  # Public entry point.
  # Order of checks (locked; do NOT reorder):
  #   1. Metacharacter rejection (binary or any arg)         → :deny / :metacharacter
  #   2. Path-shadow rejection (slash that is not canonical) → :deny / :path_shadow
  #   3. Pathmap lookup (per device.platform_name)           → :deny / :unknown_binary
  #   4. Deny-list classification                            → :needs_confirm / :deny_list
  #   5. Allow-list classification                           → :allow / :allowlisted
  #   6. Otherwise (default-deny middle zone)                → :needs_confirm / :outside_list
  def evaluate(binary:, args:, cwd:, device:)
    [binary, *Array(args)].each do |str|
      next unless str.is_a?(String)
      return Verdict.new(decision: :deny, reason: :metacharacter, resolved_binary: nil) if METACHARACTERS.any? { |m| str.include?(m) }
    end

    pathmap = BINARY_PATHS[device.platform_name.to_s] || {}

    if binary.include?("/") || binary.include?("\\")
      return Verdict.new(decision: :deny, reason: :path_shadow, resolved_binary: nil) unless pathmap.value?(binary)

      bare_name = pathmap.invert[binary]
    else
      bare_name = binary
    end

    resolved = pathmap[bare_name]
    return Verdict.new(decision: :deny, reason: :unknown_binary, resolved_binary: nil) if resolved.nil?

    return Verdict.new(decision: :needs_confirm, reason: :deny_list, resolved_binary: resolved) if DENY_LIST.include?(bare_name)

    linux_platform = device.platform_name.to_s == "linux"
    return Verdict.new(decision: :allow, reason: :allowlisted, resolved_binary: resolved) if linux_platform && ALLOW_LIST.include?(bare_name)

    Verdict.new(decision: :needs_confirm, reason: :outside_list, resolved_binary: resolved)
  end

  # Boot-time fail-closed forensics check. Logs missing paths; does NOT raise.
  # Skips paths for non-host platforms.
  def warn_missing_paths!
    BINARY_PATHS.each do |platform, mapping|
      next if platform == "windows" && !RUBY_PLATFORM.include?("mswin") && !RUBY_PLATFORM.include?("mingw")
      next if platform == "linux" && !RUBY_PLATFORM.include?("linux")

      mapping.each do |bare_name, abs_path|
        Rails.logger.warn "[CommandPolicy] missing binary on #{platform}: #{bare_name} -> #{abs_path}" unless File.exist?(abs_path)
      end
    end
  end
end
