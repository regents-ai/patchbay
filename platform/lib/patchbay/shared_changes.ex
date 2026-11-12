defmodule Patchbay.SharedChanges do
  @moduledoc """
  Changes made on any Regent site reach Patchbay's open pages, as in the Regent
  template: a pairing made or ended (`RegentAgents.Listener`) arrives as a
  database notice. It listens on one connection of Patchbay's own,
  `Patchbay.Notifications` (`Patchbay.DatabaseConfig.notifications_config/1`).
  The connection starts first, so a new connection brings a new listener.
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    connection = Patchbay.DatabaseConfig.notifications_config(Patchbay.Repo.config())

    children = [
      {Postgrex.Notifications, [name: Patchbay.Notifications] ++ connection},
      RegentAgents.Listener
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
