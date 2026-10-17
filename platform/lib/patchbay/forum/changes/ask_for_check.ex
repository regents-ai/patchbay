defmodule Patchbay.Forum.Changes.AskForCheck do
  @moduledoc """
  What every ask for a site's check (`Patchbay.Forum.SiteCheck`) does: keeps
  the site's registrable domain, marks when it was asked, and queues the
  check's job in the same write when the check is now on its way.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.SiteCheck

  @impl true
  def change(changeset, _opts, context) do
    case Origin.normalize(Ash.Changeset.get_argument(changeset, :domain)) do
      {:ok, domain} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:domain, domain)
        |> Ash.Changeset.force_change_attribute(:requested_at, DateTime.utc_now())
        |> Ash.Changeset.after_action(fn _changeset, check -> queue(check, context) end)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :domain, message: message)
    end
  end

  defp queue(check, context) do
    if SiteCheck.pending?(check) do
      opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant])
      AshOban.run_trigger(check, :run, opts)
    end

    {:ok, check}
  end
end
