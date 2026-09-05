defmodule Patchbay.Patchbay.Types.VisibleState do
  @moduledoc """
  What a room looked like on screen at one moment: the editor revision counter,
  what the Source and Candidate editors held, and which tool contract and browser
  session the observation came from.

  Naming the fields here is what gives every reader one key style. Ash casts the
  map on the way into PostgreSQL and again on the way back out, so a snapshot
  taken in Elixir and the same snapshot read back from JSONB are the same map,
  and nil stays nil rather than becoming a missing key.
  """

  @editor_fields [
    preserve_nil_values?: true,
    fields: [
      present: [type: :boolean],
      sha256: [type: :string]
    ]
  ]

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      preserve_nil_values?: true,
      fields: [
        ui_revision: [type: :integer],
        source: [type: :map, constraints: @editor_fields],
        candidate: [type: :map, constraints: @editor_fields],
        tool_contract_sha256: [type: :string],
        browser_session_id: [type: :string]
      ]
    ]
end
