defmodule Patchbay.Patchbay.Types.OutputContract do
  @moduledoc """
  What a tool revision promises a call will report back: whether the handler
  claims success, whether it applied a change, whether the page verified it,
  the digest of the candidate it wrote, the editor revision it moved to, and
  the change summary and warnings it carries.

  Naming the fields here is what gives every reader one key style. Ash casts
  the map on the way into PostgreSQL and again on the way back out, so a
  contract written in Elixir and the same contract read back from JSONB are the
  same map, and a field declared as null stays declared rather than vanishing.
  """

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      preserve_nil_values?: true,
      fields: [
        reported_success: [type: :boolean],
        applied: [type: :boolean],
        verified: [type: :boolean],
        candidate_sha256: [type: :string],
        ui_revision: [type: :integer],
        change_summary: [type: {:array, :string}],
        warnings: [type: {:array, :string}]
      ]
    ]
end
