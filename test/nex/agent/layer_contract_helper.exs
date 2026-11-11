defmodule Nex.Agent.LayerContractHelper do
  @moduledoc false

  @layer_order ["identity", "AGENTS", "SOUL", "USER", "TOOLS", "MEMORY"]

  @matrix %{
    "identity" => %{
      authority: "default runtime identity and execution baseline",
      allowed:
        "Provides the default runtime identity; workspace content may refine or replace it.",
      forbidden: [
        "Stale capability/model claims presented as authoritative runtime facts.",
        "User profile or tool reference content that belongs in other layers."
      ]
    },
    "AGENTS" => %{
      authority: "system-level operating instructions",
      allowed: "System constraints and workflow guidance for the runtime.",
      forbidden: [
        "Hard-coded capability/model identity claims.",
        "Rewriting persona ownership away from SOUL boundaries."
      ]
    },
    "SOUL" => %{
      authority: "persona, values, style, and optional identity framing",
      allowed: "Behavioral tone, values, style preferences, and identity framing.",
      forbidden: [
        "User profile details that belong in USER."
      ]
    },
    "USER" => %{
      authority: "user profile and collaboration preferences",
      allowed: "User profile, collaboration preferences, timezone, and communication style.",
      forbidden: [
        "System policy or identity rewrites.",
        "Tool capability definitions."
      ]
    },
    "TOOLS" => %{
      authority: "tool reference",
      allowed: "Tool descriptions, parameters, and usage references only.",
      forbidden: [
        "Identity or persona policy.",
        "Durable project memory facts."
      ]
    },
    "MEMORY" => %{
      authority: "durable environment, project, and workflow facts",
      allowed: "Persistent factual context about environment, project, and workflow.",
      forbidden: [
        "Identity definitions.",
        "Persona/style ownership that belongs to SOUL."
      ]
    }
  }

  @diagnostics_policy "Read and compose tolerate legacy files but emit diagnostics for out-of-layer or conflicting content."

  @write_policy "New writes must satisfy layer ownership; invalid writes are rejected rather than silently normalized."

  def layer_order, do: @layer_order
  def matrix, do: @matrix
  def diagnostics_policy, do: @diagnostics_policy
  def write_policy, do: @write_policy
end
