defmodule Patchbay.Assist.Changes.OpenFree do
  @moduledoc """
  Fills a free run in from the request the page door already checked, under
  the grant the allowance gave, for the person signed in on the page if any.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    request = Ash.Changeset.get_argument(changeset, :request)

    Ash.Changeset.force_change_attributes(changeset, %{
      payer_profile_id: payer(context),
      browser_session_id: Ash.Changeset.get_argument(changeset, :browser_session_id),
      visitor_key: Ash.Changeset.get_argument(changeset, :visitor_key),
      grant: Ash.Changeset.get_argument(changeset, :grant),
      goal: request["goal"],
      site_url: request["site_url"],
      expected_result: request["expected_result"],
      sign_in: request["sign_in"],
      believed_calls: request["believed_calls"]
    })
  end

  defp payer(%{actor: %{id: id}}), do: id
  defp payer(_anonymous), do: nil
end
