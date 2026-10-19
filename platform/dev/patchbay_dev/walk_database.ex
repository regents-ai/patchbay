defmodule PatchbayDev.WalkDatabase do
  @moduledoc """
  The browser walk signs people in on, and drops, only a walk's own local
  database: `patchbay_dev_browser_<port>` on this machine
  (assets/test/browser/support/sign_in.exs and drop.exs).
  """

  @this_machine ["127.0.0.1", "localhost", "::1"]

  @doc "The repository settings, when they name a walk's own local database; raises otherwise."
  @spec own!(keyword()) :: keyword()
  def own!(repo) do
    if to_string(repo[:hostname]) in @this_machine and
         Regex.match?(~r/\Apatchbay_dev_browser_\d+\z/, to_string(repo[:database])),
       do: repo,
       else: raise(ArgumentError, "the browser walk uses only its own local database")
  end
end
