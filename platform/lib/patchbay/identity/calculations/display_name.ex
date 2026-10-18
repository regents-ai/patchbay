defmodule Patchbay.Identity.Calculations.DisplayName do
  @moduledoc """
  A person's Regents account name, the one they set on any Regent site
  (`RegentIdentity.ProfileName`), for a profile or account with a
  `privy_user_id`. It is nil until they set one, for a wallet author (which has
  no Regents account), and on a deployment where signing in is not set up.
  """

  use Ash.Resource.Calculation

  alias Patchbay.Identity.Privy

  @impl true
  def load(_query, _opts, _context), do: [:privy_user_id]

  @impl true
  def calculate(records, _opts, context) do
    people = Enum.filter(records, & &1.privy_user_id)

    with {:ok, names} <- names(people, Privy.app_id(), context) do
      names = people |> Enum.map(& &1.privy_user_id) |> Enum.zip(names) |> Map.new()
      {:ok, Enum.map(records, &names[&1.privy_user_id])}
    end
  end

  defp names(people, nil, _context), do: {:ok, Enum.map(people, fn _person -> nil end)}
  defp names([], _app_id, _context), do: {:ok, []}

  defp names(people, _app_id, context),
    do: RegentIdentity.ProfileName.calculate(people, [otp_app: :patchbay], context)
end
