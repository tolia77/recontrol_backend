# frozen_string_literal: true

module AiTools
  # TOOL-02: list the top 100 processes on the operator's connected desktop,
  # sorted by CPU usage descending. Wire payload maps to the existing
  # `terminal.listProcesses` desktop command (TOOL-08); top-100 cap is enforced
  # server-side in `parse_response` regardless of how many processes the
  # desktop sends back.
  class ListProcesses < Base
    NAME        = "list_processes"
    DESCRIPTION = "List up to 100 processes on the operator's connected desktop, " \
                  "sorted by memory usage (descending). Returns an array of " \
                  "{ pid, command, memory_mb, cpu_time }. " \
                  "`cpu_time` is total CPU time consumed since process start " \
                  "(formatted as HH:MM:SS.fffffff); the platform does not " \
                  "expose instantaneous CPU% via this API."
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
      # The desktop returns the process list as a raw array under `result`
      # (List<ProcessInfo> serialised directly), NOT a hash wrapper. Its
      # field names are C# PascalCase: Pid, Name, MemoryMB, CpuTime,
      # StartTime. Normalise to the snake_case shape the LLM expects.
      raw = response[:result]
      return { processes: [] } unless raw.is_a?(Array)

      normalised = raw.map do |proc_info|
        {
          pid:       proc_info[:Pid],
          command:   proc_info[:Name],
          memory_mb: proc_info[:MemoryMB],
          cpu_time:  proc_info[:CpuTime]
        }
      end

      # Stable sort by memory_mb descending; preserve original order for
      # ties via the index tiebreaker. Take TOP_N (TOOL-02 cap).
      ranked = normalised
               .each_with_index
               .sort_by { |proc_info, idx| [-(proc_info[:memory_mb] || 0).to_i, idx] }
               .map { |proc_info, _idx| proc_info }
               .first(TOP_N)
      { processes: ranked }
    end
  end
end
