defmodule Nex.SkillRuntime.Evolver do
  @moduledoc false

  alias Nex.Agent.Workspace
  alias Nex.SkillRuntime.{Package, Registry, Store, Validator}

  @spec evolve(map(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def evolve(trace, opts \\ []) when is_map(trace) do
    requests = evolution_requests(trace)

    events =
      Enum.map(requests, fn request ->
        case apply_request(request, trace, opts) do
          {:ok, event} ->
            Store.append_lineage_event(event, opts)
            event

          {:error, event} ->
            Store.append_lineage_event(event, opts)
            event
        end
      end)

    {:ok, events}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp evolution_requests(trace) do
    explicit =
      trace[:evolution_requests] || trace["evolution_requests"] || []

    if is_list(explicit) do
      Enum.map(explicit, &normalize_request/1)
    else
      []
    end
  end

  defp normalize_request(request) when is_map(request) do
    Enum.into(request, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp apply_request(%{"kind" => "fix"} = request, trace, opts),
    do: apply_fix(request, trace, opts)

  defp apply_request(%{"kind" => "derived"} = request, trace, opts),
    do: apply_new_package("DERIVED", request, trace, opts)

  defp apply_request(%{"kind" => "captured"} = request, trace, opts),
    do: apply_new_package("CAPTURED", request, trace, opts)

  defp apply_request(request, trace, _opts),
    do: {:error, rejected_event(request, trace, "unsupported_kind")}

  defp apply_fix(request, trace, opts) do
    skill_id = request["skill_id"] || request["target_skill_id"]
    stage_dir = stage_dir_for(skill_id || "fix", opts)

    with true <-
           (is_binary(skill_id) and skill_id != "") ||
             {:error, rejected_event(request, trace, "missing_skill_id")},
         %Package{} = package <-
           Registry.package_by_skill_id(skill_id, opts) ||
             {:error, rejected_event(request, trace, "skill_not_found")},
         :ok <- File.rm_rf(stage_dir),
         {:ok, _} <- File.cp_r(package.root_path, stage_dir),
         :ok <- write_package_contents(stage_dir, request, trace, package),
         {:ok, staged_package} <- Package.from_dir(stage_dir),
         :ok <- Validator.validate_package(staged_package) do
      Store.snapshot_package(package, opts)
      File.rm_rf!(package.root_path)
      File.mkdir_p!(Path.dirname(package.root_path))
      File.cp_r!(stage_dir, package.root_path)

      {:ok, updated_package} = Package.from_dir(package.root_path)
      Store.upsert_packages([updated_package], opts)
      Registry.reload(opts)

      {:ok,
       %{
         "kind" => "FIX",
         "skill_id" => updated_package.skill_id,
         "parent_ids" => [package.skill_id],
         "run_id" => trace[:run_id] || trace["run_id"],
         "summary" => request["description"] || "Auto-fixed runtime package #{package.name}",
         "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "root_path" => updated_package.root_path
       }}
    else
      {:error, event} ->
        snapshot_rejected(stage_dir, "FIX", trace, opts)
        {:error, event}

      error ->
        snapshot_rejected(stage_dir, "FIX", trace, opts)
        {:error, rejected_event(request, trace, inspect(error))}
    end
  end

  defp apply_new_package(kind, request, trace, opts) do
    name = request["name"] || inferred_name(String.downcase(kind), trace)
    stage_dir = stage_dir_for("#{kind}-#{name}", opts)
    target_dir = target_dir_for(name, trace, opts)

    with :ok <- ensure_target_absent(target_dir, request, trace),
         :ok <- File.rm_rf(stage_dir),
         :ok <- File.mkdir_p(stage_dir),
         :ok <- write_package_contents(stage_dir, request, trace, nil, kind: kind),
         {:ok, staged_package} <- Package.from_dir(stage_dir),
         :ok <- Validator.validate_package(staged_package) do
      File.mkdir_p!(Path.dirname(target_dir))
      File.cp_r!(stage_dir, target_dir)
      {:ok, package} = Package.from_dir(target_dir)
      Store.upsert_packages([package], opts)
      Registry.reload(opts)

      {:ok,
       %{
         "kind" => kind,
         "skill_id" => package.skill_id,
         "parent_ids" => normalize_parent_ids(request["parent_ids"]),
         "run_id" => trace[:run_id] || trace["run_id"],
         "summary" => request["description"] || "#{kind} runtime package #{package.name}",
         "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "root_path" => package.root_path
       }}
    else
      {:error, event} ->
        snapshot_rejected(stage_dir, kind, trace, opts)
        {:error, event}

      error ->
        snapshot_rejected(stage_dir, kind, trace, opts)
        {:error, rejected_event(request, trace, inspect(error))}
    end
  end

  defp write_package_contents(target_dir, request, trace, existing_package, extra \\ []) do
    kind = Keyword.get(extra, :kind, "FIX")
    name = request["name"] || existing_name(existing_package)

    description =
      request["description"] || existing_description(existing_package) ||
        "#{kind} runtime package"

    content = request["content"] || default_content(kind, trace, existing_package)

    references =
      normalize_list(request["references"] || existing_references(existing_package) || [])

    execution_mode =
      request["execution_mode"] || existing_execution_mode(existing_package) ||
        infer_execution_mode(request)

    version = if(existing_package, do: existing_package.manifest.version + 1, else: 1)
    entry_script = request["entry_script"] || existing_entry_script(existing_package)
    source_payload = source_payload(kind, request, trace, existing_package)

    File.write!(
      Path.join(target_dir, "SKILL.md"),
      build_skill_markdown(
        name,
        description,
        content,
        references,
        execution_mode,
        version,
        entry_script
      )
    )

    write_skill_id!(target_dir, existing_package, "#{kind}:#{name}")
    write_source_json!(target_dir, source_payload)

    artifacts =
      request["files"]
      |> normalize_files()

    Enum.each(artifacts, fn {relative_path, file_content} ->
      absolute_path = Package.safe_join(target_dir, relative_path)

      if is_binary(absolute_path) do
        File.mkdir_p!(Path.dirname(absolute_path))
        File.write!(absolute_path, file_content)
      end
    end)

    :ok
  end

  defp build_skill_markdown(
         name,
         description,
         content,
         references,
         execution_mode,
         version,
         entry_script
       ) do
    lines =
      [
        "---",
        "name: #{yaml_scalar(name)}",
        "description: #{yaml_scalar(description)}",
        "execution_mode: #{execution_mode}",
        "version: #{version}"
      ] ++
        maybe_entry_script(entry_script, execution_mode) ++
        references_lines(references) ++
        ["---", "", String.trim(content), ""]

    Enum.join(lines, "\n")
  end

  defp maybe_entry_script(entry_script, "playbook")
       when is_binary(entry_script) and entry_script != "",
       do: ["entry_script: #{yaml_scalar(entry_script)}"]

  defp maybe_entry_script(_entry_script, _mode), do: []

  defp references_lines([]), do: []

  defp references_lines(references),
    do: ["references:" | Enum.map(references, &"  - #{yaml_scalar(&1)}")]

  defp infer_execution_mode(request) do
    if is_binary(request["entry_script"]) and request["entry_script"] != "" do
      "playbook"
    else
      "knowledge"
    end
  end

  defp source_payload(kind, request, trace, existing_package) do
    base =
      if existing_package do
        Map.merge(existing_package.source || %{}, %{
          "active" => true,
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      else
        %{
          "active" => true,
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      end

    base
    |> Map.put("source_type", String.downcase(kind))
    |> Map.put("run_id", trace[:run_id] || trace["run_id"])
    |> Map.put("parent_ids", normalize_parent_ids(request["parent_ids"]))
    |> Map.put("created_by", "skill_runtime_evolve")
  end

  defp normalize_parent_ids(parent_ids) when is_list(parent_ids),
    do: Enum.map(parent_ids, &to_string/1)

  defp normalize_parent_ids(_), do: []

  defp normalize_files(map) when is_map(map) do
    Enum.into(map, %{}, fn {path, content} -> {to_string(path), to_string(content)} end)
  end

  defp normalize_files(_), do: %{}

  defp stage_dir_for(seed, opts) do
    Path.join(
      Store.cache_dir(opts),
      "evolve/#{Package.slugify(to_string(seed))}-#{System.unique_integer([:positive])}"
    )
  end

  defp target_dir_for(name, trace, opts) do
    base = Path.join(Workspace.skills_dir(opts), "rt__#{Package.slugify(name)}")

    if File.exists?(base) do
      suffix =
        :crypto.hash(:sha256, "#{trace[:run_id] || trace["run_id"]}:#{name}")
        |> Base.encode16(case: :lower)
        |> String.slice(0, 6)

      base <> "__" <> suffix
    else
      base
    end
  end

  defp write_skill_id!(target_dir, %Package{} = package, _seed) do
    File.write!(Path.join(target_dir, ".skill_id"), package.skill_id <> "\n")
  end

  defp write_skill_id!(target_dir, _package, seed) do
    skill_id =
      "skill_" <>
        (:crypto.hash(:sha256, seed)
         |> Base.encode16(case: :lower)
         |> String.slice(0, 16))

    File.write!(Path.join(target_dir, ".skill_id"), skill_id <> "\n")
  end

  defp write_source_json!(target_dir, payload) do
    File.write!(Path.join(target_dir, "source.json"), Jason.encode!(payload, pretty: true))
  end

  defp ensure_target_absent(target_dir, request, trace) do
    if File.exists?(target_dir) do
      {:error, rejected_event(request, trace, "target_exists")}
    else
      :ok
    end
  end

  defp snapshot_rejected(stage_dir, kind, trace, opts) do
    if File.dir?(stage_dir) do
      rejected_dir =
        Path.join(
          Store.snapshots_dir(opts),
          "rejected/#{String.downcase(kind)}-#{trace[:run_id] || trace["run_id"] || System.unique_integer([:positive])}"
        )

      File.rm_rf!(rejected_dir)
      File.mkdir_p!(Path.dirname(rejected_dir))
      File.cp_r!(stage_dir, rejected_dir)
    end
  end

  defp rejected_event(request, trace, reason) do
    %{
      "kind" => "REJECTED",
      "requested_kind" => request["kind"],
      "run_id" => trace[:run_id] || trace["run_id"],
      "summary" => reason,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build_summary_content(label, trace) do
    """
    ## #{label} Runtime Package

    ### Prompt
    #{trace[:prompt] || trace["prompt"] || ""}

    ### Result
    #{render_text(trace[:result] || trace["result"] || "")}

    ### Tool Results
    #{Enum.map_join(trace[:tool_messages] || trace["tool_messages"] || [], "\n\n", fn msg -> "- #{msg["name"] || msg[:name]}: #{String.slice(render_text(msg["content"] || msg[:content] || ""), 0, 400)}" end)}
    """
    |> String.trim()
  end

  defp default_content("FIX", trace, %Package{} = package) do
    [
      String.trim(package.manifest.content || ""),
      "",
      "## Auto Revision",
      "- Run: #{trace[:run_id] || trace["run_id"]}",
      "- Prompt: #{trace[:prompt] || trace["prompt"] || ""}",
      "- Result: #{render_text(trace[:result] || trace["result"] || "") |> String.slice(0, 600)}"
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp default_content(kind, trace, _existing_package), do: build_summary_content(kind, trace)

  defp inferred_name(prefix, trace) do
    prompt_slug =
      trace[:prompt] || trace["prompt"] ||
        prefix
        |> Package.slugify()
        |> String.slice(0, 32)

    "#{prefix}_#{prompt_slug}"
  end

  defp existing_name(%Package{} = package), do: package.name
  defp existing_name(_), do: nil

  defp existing_description(%Package{} = package), do: package.manifest.description
  defp existing_description(_), do: nil

  defp existing_references(%Package{} = package), do: package.manifest.references
  defp existing_references(_), do: []

  defp existing_execution_mode(%Package{} = package), do: package.execution_mode
  defp existing_execution_mode(_), do: nil

  defp existing_entry_script(%Package{} = package), do: package.manifest.entry_script
  defp existing_entry_script(_), do: nil

  defp render_text(value) when is_binary(value), do: value
  defp render_text(value), do: inspect(value)

  defp yaml_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp yaml_scalar(value), do: to_string(value)

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(value) when is_binary(value), do: [String.trim(value)]
  defp normalize_list(_), do: []
end
