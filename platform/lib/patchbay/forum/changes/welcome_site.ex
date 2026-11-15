defmodule Patchbay.Forum.Changes.WelcomeSite do
  @moduledoc """
  A post adds its site to the directory. In the same write it asks for a
  check of the site when there is no fresh one, records a fresh check's
  WebMCP tools when the board offers none yet, and asks for the picture of
  the site's page that its card shows (`Patchbay.Forum.Site`'s `:take_picture`).
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteCheck
  alias Patchbay.Forum.Tool

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, thread ->
      # Patchbay's own bookkeeping after the post: no actor's say.
      site = Forum.get_site!(thread.site_id, authorize?: false)
      check = Forum.get_site_check(site.origin, authorize?: false, not_found_error?: false)

      with {:ok, check} <- check, do: look_at(site, check)

      AshOban.run_trigger(site, :take_picture)
      {:ok, thread}
    end)
  end

  # Asked for by the post, not the poster, so it is not counted against them.
  defp look_at(site, check) do
    cond do
      SiteCheck.due?(check) -> Forum.request_site_check!(site.origin, authorize?: false)
      offers_none?(site) -> SiteCheck.record_tools(site, check)
      true -> :ok
    end
  end

  # Whether the board lists no current tool yet: Patchbay's own bookkeeping,
  # so no actor's say.
  defp offers_none?(site),
    do:
      not (Tool
           |> Ash.Query.filter(site_id == ^site.id and current?)
           |> Ash.exists?(authorize?: false))
end
