defmodule Nex.SkillRuntime.ExecutionTrace do
  @moduledoc false

  defstruct run_id: nil,
            prompt: nil,
            selected_packages: [],
            tool_messages: [],
            result: nil,
            status: "completed",
            inserted_at: nil
end
