# frozen_string_literal: true

module AiTools
  # TOOL-04: list directory entries on the operator's connected desktop.
  # Wire payload maps to the existing `filemanager.list` desktop command
  # (TOOL-08); the v1.2 file-manager allowlist + canonicalisation is enforced
  # desktop-side. Phase 18's contribution is the type-validated dispatch path
  # plus a 200-entry server-side cap (TOOL-04) and surfacing of the desktop's
  # allowlist-refusal error to the LLM as a `{ error: "..." }` envelope.
  class ListFiles < Base
    NAME        = "list_files"
    DESCRIPTION = "List directory entries on the operator's connected desktop. " \
                  "The path must be inside the desktop's configured allowlisted roots " \
                  "(v1.2 file manager). Returns up to 200 entries."
    HUMAN_LABEL = "List files"

    MAX_ENTRIES = 200

    SCHEMA = Dry::Schema.JSON do
      required(:path).filled(:string)
    end

    private

    def policy_verdict(_args)
      CommandPolicy::Verdict.new(
        decision: :allow,
        reason: :read_only_tool,
        resolved_binary: nil
      )
    end

    def build_payload(args)
      { command: "filemanager.list", payload: { path: args[:path] } }
    end

    def parse_response(response)
      # Surface explicit desktop errors (e.g. allowlist refusal) into the
      # LLM's tool result so the model does not retry blindly. Phase 19 may
      # add structured error categorisation; Phase 18 just passes through.
      err = response.dig(:result, :error)
      err ||= response[:error] if response[:status] == "error"
      return { error: err } if err

      entries = response.dig(:result, :entries) || []
      { entries: entries.first(MAX_ENTRIES) }
    end
  end
end
