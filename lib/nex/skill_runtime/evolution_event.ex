defmodule Nex.SkillRuntime.EvolutionEvent do
  @moduledoc false

  defstruct kind: nil,
            skill_id: nil,
            parent_ids: [],
            summary: nil,
            created_at: nil
end
