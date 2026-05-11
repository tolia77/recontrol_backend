# frozen_string_literal: true

module AiTools
  # TOOL-03: terminate a process by integer PID. Wire payload maps to the
  # existing `process.kill` desktop command (TOOL-08). Per RF-4 / D-10,
  # `Dry::Schema.JSON` (not `.Params`) is used so a string `"1234"` from a
  # confused LLM is REJECTED as invalid_arguments rather than silently
  # coerced to integer 1234 -- which would defeat the type contract that
  # this tool is supposed to express to the model.
  #
  # The Phase 19 safety layer adds operator-confirmation gating for
  # destructive tools; Phase 18's contribution is the type-validated
  # dispatch path (D-12 / TOOL-06).
  class KillProcess < Base
    NAME        = "kill_process"
    DESCRIPTION = "Terminate a process on the operator's connected desktop by integer PID. " \
                  "Always classified as destructive (Phase 19 adds operator confirmation; " \
                  "in Phase 18 the call dispatches after dry-schema type-validation only)."
    HUMAN_LABEL = "Kill process"

    SCHEMA = Dry::Schema.JSON do
      required(:pid).filled(:integer, gt?: 0)
    end

    private

    def policy_verdict(_args)
      CommandPolicy::Verdict.new(
        decision: :needs_confirm,
        reason: :destructive_tool,
        resolved_binary: nil
      )
    end

    def build_payload(args)
      { command: "process.kill", payload: { pid: args[:pid] } }
    end

    def parse_response(response)
      {
        killed: response.dig(:result, :killed),
        error:  response.dig(:result, :error)
      }.compact
    end
  end
end
