# frozen_string_literal: true

module AiTools
  # TOOL-02: list the top 100 processes on the operator's connected desktop,
  # sorted by CPU usage descending. Wire payload maps to the existing
  # `terminal.listProcesses` desktop command (TOOL-08); top-100 cap is enforced
  # server-side in `parse_response` regardless of how many processes the
  # desktop sends back.
  class ListProcesses < Base
    NAME        = "list_processes"
    DESCRIPTION = "List the top 100 processes on the operator's connected desktop, " \
                  "sorted by CPU usage (descending). Returns an array of " \
                  "{ pid, command, cpu_percent, memory_percent }."
    HUMAN_LABEL = "List processes"

    TOP_N = 100

    # No required fields. Dry::Schema.JSON allows the empty-args form
    # `{}` from OpenRouter's tool_call.
    SCHEMA = Dry::Schema.JSON do
    end

    private

    def policy_verdict(_args)
      CommandPolicy::Verdict.new(
        decision: :allow,
        reason: :read_only_tool,
        resolved_binary: nil
      )
    end

    def build_payload(_args)
      { command: "terminal.listProcesses", payload: {} }
    end

    def parse_response(response)
      processes = response.dig(:result, :processes) || []
      # Stable sort by cpu_percent descending; preserve original order for
      # ties via the index tiebreaker. Take TOP_N (TOOL-02 cap).
      ranked = processes
               .each_with_index
               .sort_by { |proc_info, idx| [-(proc_info[:cpu_percent] || 0).to_f, idx] }
               .map { |proc_info, _idx| proc_info }
               .first(TOP_N)
      { processes: ranked }
    end
  end
end
