# frozen_string_literal: true

require "dry-schema"
require "securerandom"

# AiTools is the umbrella module for the four LLM-callable tools (run_command,
# list_processes, kill_process, list_files). Each concrete tool subclasses
# AiTools::Base; the Base.const_added(:NAME) hook auto-registers the subclass
# under its NAME so `AiTools.fetch("run_command")` returns the class object.
#
# config/application.rb pushes this directory as a Zeitwerk namespaced root
# (so app/ai_tools/base.rb -> AiTools::Base, not top-level Base) AND eager-
# loads every concrete tool at boot via `config.after_initialize` so the
# REGISTRY is populated before AgentRunner's first AiTools.fetch call.
module AiTools
  # Process-global registry: tool name (string) -> AiTools::Base subclass.
  # D-10: One Ruby class per tool. Adding a fifth tool in v1.5 means just
  # `class NewTool < AiTools::Base` -- no manual registration call needed.
  REGISTRY = {}

  module_function

  # Register a tool class under its NAME constant. Called automatically from
  # the Base.const_added(:NAME) hook (see Base below). Subclasses without a
  # NAME constant (i.e. abstract intermediates or test stubs created via
  # `Class.new(Base)`) are skipped so they do not pollute the registry.
  def register(klass)
    return unless klass.const_defined?(:NAME, false) && klass::NAME
    REGISTRY[klass::NAME] = klass
  end

  # AgentRunner (Plan 5) calls this to look up the class for an emitted
  # tool_call. Raises ArgumentError on unknown name; AgentRunner converts
  # that into a `{error: "unknown_tool"}` tool result and lets the loop
  # iterate one turn.
  def fetch(name)
    REGISTRY.fetch(name) { raise ArgumentError, "Unknown AI tool: #{name}" }
  end

  # OpenRouterClient (via AgentRunner) consumes this for the `tools:` field
  # of every request. D-13: dry-schema -> JSON Schema is the single source
  # of truth.
  def all_definitions
    REGISTRY.values.map(&:to_openrouter_definition)
  end

  class Base
    # Subclass-overridable constants. Keeping them nil here means a subclass
    # that forgets to declare them raises on first use (rather than silently
    # registering a malformed tool definition under the nil key).
    NAME        = nil  # OpenRouter function name, e.g. "run_command"
    DESCRIPTION = nil  # Human description in the OpenRouter tool definition
    HUMAN_LABEL = nil  # STREAM-07: short label broadcast in tool_call_start
    SCHEMA      = nil  # Dry::Schema.JSON { ... } -- per RF-4 (JSON, not Params)

    # Auto-register on inheritance (D-10). At the moment `inherited` fires the
    # subclass body has not yet executed, so `subclass::NAME` is still nil --
    # `AiTools.register` is intentionally a no-op for nil names. The real
    # registration happens in `const_added(:NAME)` below, which fires the
    # instant the subclass assigns its NAME constant. Calling register from
    # both hooks is idempotent (same hash key, same value).
    def self.inherited(subclass)
      super
      AiTools.register(subclass)
    end

    # Ruby 3.2+ hook: fires on every constant assignment in the class body.
    # The actual registration moment for a concrete tool -- by the time NAME
    # is being set, every other constant the subclass declared (DESCRIPTION,
    # SCHEMA, HUMAN_LABEL) is normally already in place because tool files
    # declare NAME first. The order does not matter for the registry write
    # itself, only for `to_openrouter_definition` callers.
    def self.const_added(const_name)
      super
      return unless const_name == :NAME
      return if self == AiTools::Base
      AiTools.register(self)
    end

    # D-13: emit the OpenRouter `tools` array entry. Requires the
    # `:json_schema` extension (loaded in config/initializers/dry_schema.rb).
    # dry-schema 1.16 returns the json_schema with symbol keys; OpenRouter's
    # `tools[].function.parameters` field is a JSON Schema object whose
    # idiomatic shape uses string keys (and tests assert `"type" => "object"`).
    # Deep-stringify so both the wire JSON and Ruby-shape match.
    def self.to_openrouter_definition
      raise NotImplementedError, "#{self} must declare NAME"        unless self::NAME
      raise NotImplementedError, "#{self} must declare DESCRIPTION" unless self::DESCRIPTION
      raise NotImplementedError, "#{self} must declare SCHEMA"      unless self::SCHEMA

      {
        type: "function",
        function: {
          name: self::NAME,
          description: self::DESCRIPTION,
          parameters: self::SCHEMA.json_schema.deep_stringify_keys
        }
      }
    end

    def initialize(device:)
      @device = device
    end

    # Template method: validate -> build_payload -> dispatch -> parse_response.
    # Returns one of:
    #   { error: "invalid_arguments", details: {...} }   (D-12, schema failure)
    #   { error: "tool_timeout" }                         (TOOL-07, propagated from CommandBridge)
    #   <subclass parse_response shape>                   (success)
    def call(args)
      result = self.class::SCHEMA.call(args || {})
      return { error: "invalid_arguments", details: result.errors.to_h } if result.failure?

      payload      = build_payload(result.to_h)
      tool_call_id = SecureRandom.uuid
      response     = CommandBridge.dispatch(
        device: @device,
        payload: payload,
        tool_call_id: tool_call_id
      )

      # CommandBridge timeout passthrough: do NOT call parse_response on a
      # tool_timeout envelope -- the desktop sent nothing to parse.
      return response if response.is_a?(Hash) && response[:error] == "tool_timeout"

      parse_response(response)
    end

    private

    def build_payload(_args)
      raise NotImplementedError, "#{self.class} must implement #build_payload"
    end

    def parse_response(_response)
      raise NotImplementedError, "#{self.class} must implement #parse_response"
    end
  end
end
