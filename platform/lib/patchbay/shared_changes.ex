defmodule Patchbay.SharedChanges do
  @moduledoc """
  Changes made on any Regent site reach Patchbay's open pages, as in the Regent
  template: a Credits balance (`RegentCredits.Listener`) and a pairing made or
  ended (`RegentAgents.Listener`) arrive as database notices. Both listen on one
  connection of Patchbay's own, `Patchbay.Notifications`
  (`Patchbay.DatabaseConfig.notifications_config/1`). The connection starts
  first, so a new connection brings new listeners.
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    connection = Patchbay.DatabaseConfig.notifications_config(Patchbay.Repo.config())

    children = [
      {Postgrex.Notifications, [name: Patchbay.Notifications] ++ connection},
      RegentCredits.Listener,
      RegentAgents.Listener
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
