defmodule Patchbay.Forum.Types.CveSeverity do
  @moduledoc """
  How severe a vulnerability copied from cve.now is: the level cve.now
  states, or else the band its CVSS score falls in
  (`Patchbay.Incidents.CveNow.Post`).
  """

  use Ash.Type.Enum,
    values: [
      critical: [description: "CVSS 9.0 to 10.0."],
      high: [description: "CVSS 7.0 to 8.9."],
      medium: [description: "CVSS 4.0 to 6.9."],
      low: [description: "CVSS 0.1 to 3.9."],
      none: [description: "CVSS 0.0."]
    ]
end
