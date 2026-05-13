# frozen_string_literal: true

module AiTools
  # TOOL-01: execute a command on the operator's connected desktop.
  # Dispatches `terminal.runCommand` -- the one-shot execve path that uses
  # Process.Start with discrete args (no shell parsing). Distinct from
  # `terminal.execute` which runs through a persistent /bin/bash session and
  # streams output as separate frames; that streaming-shell semantics is
  # wrong for AI tool calls, which need a single response keyed by the
  # request id. The discrete-args contract also preserves CommandPolicy's
  # metacharacter rejection (a shell intermediary would re-parse and
  # re-introduce the ambiguity the policy is designed to eliminate).
  class RunCommand < Base
    NAME        = "run_command"
    DESCRIPTION = "Execute a command on the operator's connected desktop. " \
                  "Returns sanitized stdout, stderr, exit code, and elapsed seconds. " \
                  "Phase 19 will enforce whitelist + metacharacter rejection; " \
                  "in Phase 18 the binary/args/cwd are passed through after dry-schema " \
                  "type-validation only."
    HUMAN_LABEL = "Run command"

    # RF-4: Dry::Schema.JSON (NOT .Params) -- arguments arrive as already-typed
    # JSON from OpenRouter; we do not want HTML-form string-coercion.
    # TOOL-06: cwd is mandatory so AgentRunner's loop-detector triple
    # `[binary, args, cwd]` is fully populated per CONTEXT specifics.
    SCHEMA = Dry::Schema.JSON do
      required(:binary).filled(:string)
      required(:args).array(:string)
      required(:cwd).filled(:string)
    end

    private

    def build_payload(args)
      {
        command: "terminal.runCommand",
        payload: {
          binary: args[:binary],
          args:   args[:args],
          cwd:    args[:cwd]
        }
      }
    end

    def parse_response(response)
      {
        stdout:  response.dig(:result, :stdout),
        stderr:  response.dig(:result, :stderr),
        exit:    response.dig(:result, :exit_code),
        elapsed: response.dig(:result, :elapsed_seconds)
      }
    end
  end
end
