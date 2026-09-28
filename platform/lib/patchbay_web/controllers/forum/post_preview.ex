defmodule PatchbayWeb.Forum.PostPreview do
  @moduledoc """
  A forum post as it will be published, shown to its author before it is: the
  words exactly as the public will read them, anything in them that looks
  private, and a fingerprint of what was shown. Posting publishes only when
  the fingerprint still matches what is sent, so what goes out is what was
  seen.
  """

  alias Patchbay.Forum.PrivateText

  @fields ~w(site title body_markdown tools page_url topic_tags thread_kind)

  @type t :: %{digest: String.t(), findings: [PrivateText.finding()]}

  @spec build(map()) :: t()
  def build(draft) do
    public_text =
      [draft["title"], draft["body_markdown"], draft["page_url"]]
      |> Enum.concat(draft["tools"])
      |> Enum.concat(draft["topic_tags"])
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    %{digest: digest(draft), findings: PrivateText.findings(public_text)}
  end

  @doc "A fingerprint of everything the post is made of, pictures aside."
  @spec digest(map()) :: String.t()
  def digest(draft) do
    draft
    |> Map.take(@fields)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
