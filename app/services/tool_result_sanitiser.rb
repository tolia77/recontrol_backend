# frozen_string_literal: true

# ToolResultSanitiser
# -------------------
# Invoked by AiTools::Base#call after parse_response and before tool results are
# appended to the model message stream or broadcast to the operator transcript.
# The sanitiser recursively walks Hash / Array / String values and applies the
# locked SAFETY-11 pipeline to String values only:
#
#   1) Strip ANSI escapes (7-bit, strings-ansi style)
#   2) Strip ASCII control bytes (preserving newline + tab)
#   3) Truncate with mb_chars.limit(4_096).to_s (byte budget, UTF-8 safe)
#   4) Redact secrets with fixed-order SAFETY-12 pattern passes
#
# Notes:
# - Hash keys are intentionally left untouched.
# - Numeric/boolean/nil values pass through unchanged.
# - Pipeline order is intentionally locked (ANSI before control stripping).
# - Secret pattern order is intentionally locked (specific -> generic).
module ToolResultSanitiser
  module_function

  TRUNCATE_BYTES = 4_096

  # 7-bit ANSI escape regex (vendored shape from strings-ansi).
  # Covers CSI, cursor control, OSC title/hyperlink payloads, and related
  # escape forms commonly emitted by shell tooling.
  ANSI_RE = %r{
    (?>\e(
      \[[\[?>!]?\d*(;\d+)*[ ]?[a-zA-Z~@$^\]_\{\\]
      |
      \#?\d
      |
      [)(%+\-*/. ](\d|[a-zA-Z@=%]|)
      |
      O[p-xA-Z]
      |
      [a-zA-Z=><~\}|]
      |
      \][^\x07\e]{0,2000}(?:\e\\|\x07)
      |
      \]8;[^;]*;.*?(\e\\|\x07)
    ))
  }x.freeze

  CTRL_RE = /[\x00-\x08\x0B-\x1F\x7F]/.freeze

  # SAFETY-12: fixed-order secret redaction passes.
  # - PEM block
  # - AWS access key
  # - DB URI
  # - env assignment (preserve key name, redact value only)
  # - base64 catch-all
  #
  # Replacements are the locked bare literal "[REDACTED]".
  # For env assignment we preserve the left-hand side via a backreference.
  SECRET_PATTERNS = [
    [
      /-----BEGIN [A-Z ]{1,40}PRIVATE KEY-----[\s\S]{1,8000}?-----END [A-Z ]{1,40}PRIVATE KEY-----/,
      "[REDACTED]"
    ],
    [
      /\b(?:AKIA|ASIA|AROA|AIDA|AGPA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b/,
      "[REDACTED]"
    ],
    [
      %r{\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?)://[^\s'"]{1,500}}i,
      "[REDACTED]"
    ],
    [
      /\b([A-Z_][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD))\s*=\s*(?:"[^"]{1,500}"|'[^']{1,500}'|[^\s"']{1,500})/,
      '\1=[REDACTED]'
    ],
    [
      /(?<![A-Za-z0-9+\/_-])[A-Za-z0-9+\/_-]{40,}={0,2}(?![A-Za-z0-9+\/_-])/,
      "[REDACTED]"
    ]
  ].freeze

  # Recursive pure-function walker.
  def call(value)
    case value
    when Hash
      value.transform_values { |inner_value| call(inner_value) }
    when Array
      value.map { |inner_value| call(inner_value) }
    when String
      sanitise_string(value)
    else
      value
    end
  end

  # Locked SAFETY-11 pipeline:
  # ANSI -> control-char strip -> mb_chars byte truncation -> redaction.
  def sanitise_string(value)
    output = value.gsub(ANSI_RE, "")
    output = output.gsub(CTRL_RE, "")
    output = output.mb_chars.limit(TRUNCATE_BYTES).to_s
    redact_secrets(output)
  end

  # Fixed-order redaction reduce pass.
  def redact_secrets(value)
    SECRET_PATTERNS.reduce(value) do |accumulator, (pattern, replacement)|
      accumulator.gsub(pattern, replacement)
    end
  end
end
