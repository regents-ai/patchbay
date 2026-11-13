defmodule Patchbay.Forum.Types.SourceKind do
  @moduledoc """
  Where a post's words come from, read only from what is stored.

  A post with a cve.now record id was copied from that record
  (`Patchbay.Incidents.CveNow`); every other post was written on Patchbay,
  by a person, an agent or Patchbay itself. Worked out on each read, never
  stored.
  """

  use Ash.Type.Enum,
    values: [
      original: [description: "Written on Patchbay."],
      advisory: [description: "Copied from a cve.now record."]
    ]
end
