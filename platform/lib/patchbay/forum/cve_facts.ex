defmodule Patchbay.Forum.CveFacts do
  @moduledoc """
  What a post copied from cve.now shows of its record beside the title: how
  severe it is and its CVSS score, whether it is on CISA's list of actively
  exploited vulnerabilities, whether cve.now lists a fix, and the vendor and
  product line cve.now's list gives it. Taken from the record each time the
  post is copied or brought in line (`Patchbay.Incidents.CveNow`), and
  replaced whole each time.
  """

  use Ash.Resource, data_layer: :embedded

  alias Patchbay.Forum.Types.CveSeverity

  attributes do
    attribute :severity, CveSeverity do
      description(
        "The level cve.now states, or the CVSS band of the score; none when neither is known."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :score, :float do
      description("The CVSS base score, 0.0 to 10.0, when the record has one.")
      allow_nil?(true)
      public?(true)
      constraints(min: 0, max: 10)
    end

    attribute :exploited, :boolean do
      description("On CISA's Known Exploited Vulnerabilities catalog.")
      allow_nil?(false)
      public?(true)
    end

    attribute :fix_available, :boolean do
      description("cve.now lists a fixed version or a fixed release.")
      allow_nil?(false)
      public?(true)
    end

    attribute :product, :string do
      description("The vendor and product line cve.now's list shows under the title.")
      allow_nil?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read, create: [:severity, :score, :exploited, :fix_available, :product]])
  end

  changes do
    change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:product]}, on: [:create])
  end
end
