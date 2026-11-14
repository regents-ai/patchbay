defmodule Patchbay.OAuthSwitch do
  @moduledoc """
  Switches one address's sign-in (`Patchbay.OAuth`) on for a test, as
  config/runtime.exs does, with `overrides` merged into that address's
  settings. Every setting is put back when the test ends.
  """

  @spec on(PatchbayWeb.SiteEdition.t(), keyword()) :: :ok
  def on(edition, overrides \\ []) do
    all = Application.fetch_env!(:patchbay, Patchbay.OAuth)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:patchbay, Patchbay.OAuth, all) end)

    Application.put_env(
      :patchbay,
      Patchbay.OAuth,
      Keyword.update!(all, edition, &Keyword.merge(&1, Keyword.put(overrides, :enabled?, true)))
    )
  end
end
