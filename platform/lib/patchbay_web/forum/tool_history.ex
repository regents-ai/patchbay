defmodule PatchbayWeb.Forum.ToolHistory do
  @moduledoc false
  alias Patchbay.Forum
  alias PatchbayWeb.Endpoint
  @salt "tool-history-v1"

  def page(site, name, cursor \\ nil, limit \\ 25, load \\ []) do
    with {:ok, opts} <- cursor_options(cursor, site.id, name),
         {:ok, page} <-
           Forum.tool_history(site.id, name,
             page: Keyword.put(opts, :limit, limit + 1),
             query: [load: load]
           ) do
      versions = Enum.take(page.results, limit)
      more? = length(page.results) > limit

      next =
        if more?,
          do:
            Phoenix.Token.sign(
              Endpoint,
              @salt,
              {site.id, name, List.last(versions).__metadata__.keyset}
            )

      {:ok,
       %{
         versions: versions,
         comparison_versions: page.results,
         pagination: %{has_more: more?, next_cursor: next}
       }}
    end
  end

  defp cursor_options(nil, _, _), do: {:ok, []}

  defp cursor_options(cursor, site_id, name)
       when is_binary(cursor) and byte_size(cursor) <= 4096 do
    case Phoenix.Token.verify(Endpoint, @salt, cursor, max_age: 86_400) do
      {:ok, {^site_id, ^name, keyset}} when is_binary(keyset) -> {:ok, [after: keyset]}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor_options(_, _, _), do: {:error, :invalid_cursor}
end
