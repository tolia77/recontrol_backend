# frozen_string_literal: true

module ToolResultSanitiser
  module_function

  TRUNCATE_BYTES = 4_096

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

  def sanitise_string(value)
    output = value.gsub(ANSI_RE, "")
    output = output.gsub(CTRL_RE, "")
    output = output.mb_chars.limit(TRUNCATE_BYTES).to_s
    redact_secrets(output)
  end

  def redact_secrets(value)
    SECRET_PATTERNS.reduce(value) do |accumulator, (pattern, replacement)|
      accumulator.gsub(pattern, replacement)
    end
  end
end
