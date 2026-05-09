# frozen_string_literal: true

module AiTools
  # TOOL-01: execute a command on the operator's connected desktop.
  # Wire-format invariant per TOOL-08: the desktop already implements
  # `terminal.execute` with `{ binary:, args:, cwd: }` payload keys; this
  # tool produces exactly that shape so no desktop-side change is needed.
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
        command: "terminal.execute",
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
