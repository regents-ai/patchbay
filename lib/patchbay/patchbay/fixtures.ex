defmodule Patchbay.Patchbay.Fixtures do
  @moduledoc """
  Checked-in seed data every Skill Uplift room starts from.
  """

  @seed_version "skill-uplift-v1"

  def seed_version, do: @seed_version

  def source_markdown do
    fixture!("hello-greeter.md")
  end

  def improved_markdown do
    fixture!("hello-greeter-improved.md")
  end

  def repair_plan do
    fixture!("seeded-repair-plan.json") |> Jason.decode!()
  end

  def room_attributes do
    source = source_markdown()

    %{
      title: "Skill Uplift Studio",
      goal_kind: :skill_uplift,
      goal_text: "Place an improved candidate in the visible Candidate editor.",
      source_markdown: source,
      source_sha256: Patchbay.Patchbay.Digest.sha256(source),
      ui_revision: 0,
      desired_tool_generation: 1,
      seed_version: @seed_version,
      status: :ready
    }
  end

  def revision_attributes(room_id) do
    contract = %{
      name: "uplift_current_skill_v1",
      title: "Improve the current Skill",
      description:
        "Improve the Skill currently loaded in the Source editor while preserving its identity frontmatter, and place the revision in the visible Candidate editor.",
      input_schema: %{
        "type" => "object",
        "required" => ["instructions"],
        "additionalProperties" => false,
        "properties" => %{
          "instructions" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 1000,
            "description" => "A bounded description of what should be clarified or improved."
          }
        }
      },
      annotations: %{"readOnlyHint" => false, "untrustedContentHint" => true},
      handler_adapter: :return_candidate_only,
      output_contract: %{"reported_success" => true, "applied" => false},
      postcondition_set: :skill_candidate_written_v1
    }

    Map.merge(contract, %{
      room_id: room_id,
      generation: 1,
      origin: :seed,
      status: :desired,
      contract_sha256: Patchbay.Patchbay.Digest.contract_sha256(contract)
    })
  end

  defp fixture!(name) do
    :patchbay
    |> :code.priv_dir()
    |> Path.join(Path.join("patchbay/fixtures", name))
    |> File.read!()
  end
end
