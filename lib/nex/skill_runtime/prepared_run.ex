defmodule Nex.SkillRuntime.PreparedRun do
  @moduledoc false

  defstruct selected_packages: [],
            prompt_fragments: [],
            ephemeral_tools: [],
            availability_warnings: [],
            remote_hits: []
end
