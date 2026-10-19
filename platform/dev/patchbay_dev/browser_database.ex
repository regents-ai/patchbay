defmodule PatchbayDev.BrowserDatabase do
  @moduledoc """
  The database of the server the browser tests run (`assets/test/browser`).
  Every page the server answers shares one connection, held in a transaction
  that is never committed, so each run starts from the empty test database
  and leaves nothing behind when the server stops.

  `:owner` starts right after the repository, before anything reads it.
  `:sites` starts just before the endpoint and makes the catalog's sites from
  priv before the first page is served. The program's own sites, which a real
  boot also makes, need Techtree's tables, which the test database does not have.
  """

  alias Ecto.Adapters.SQL.Sandbox

  def child_spec(:owner), do: %{id: :browser_database, start: {__MODULE__, :start_owner, []}}

  def child_spec(:sites),
    do: %{id: :browser_sites, start: {__MODULE__, :make_sites, []}, restart: :temporary}

  def start_owner do
    # Held for the whole run: a checkout is otherwise taken back after two minutes.
    owner = Sandbox.start_owner!(Patchbay.Repo, shared: true, ownership_timeout: :infinity)
    Process.link(owner)
    {:ok, owner}
  end

  def make_sites do
    Patchbay.Forum.Catalog.sync!()
    :ignore
  end
end
