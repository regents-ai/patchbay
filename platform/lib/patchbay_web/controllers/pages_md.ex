defmodule PatchbayWeb.PagesMD do
  @moduledoc "The about, contact, privacy, terms and developer pages as markdown."

  use PatchbayWeb, :md

  import PatchbayWeb.PagesHTML, only: [auth_label: 1, doors_label: 1, call_json: 1]

  embed_templates("pages_md/*")

  @doc "Visitor text as the words of a markdown link: one line, brackets escaped."
  @spec link_text(String.t()) :: String.t()
  def link_text(text) do
    text |> String.replace(~r/\s+/, " ") |> String.replace(~r/[\[\]]/, "\\\\\\0")
  end
end
